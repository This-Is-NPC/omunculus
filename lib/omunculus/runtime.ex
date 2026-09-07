defmodule Omunculus.Runtime do
  @moduledoc """
  Consumer that turns accepted envelopes into Execution Nodes/Runs.

  * `task.requested` (command) starts a root Run at depth 0.
  * `task.delegated` (event) starts a child Run at `to_depth` with
    `parent_run_id`/`originating_run_id` taken from the event, so the reporting
    tree is derived from runtime links, never from Agent configuration.
  * `task.resumed` (command) derives attempt, depth, parent and checkpoint from
    the log and starts a **new** Run; the failed Run is never reopened.

  A crashed Run process is observed via monitor and recorded as `run.failed`.
  Delivery is at-least-once, so activation is deduplicated by `event_id`.
  """

  use GenServer

  alias Omunculus.EventCore
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Run
  alias Omunculus.{Config, Policy}

  # --- API ------------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Submit a task as a command and wait for the root `task.completed`.
  Returns `{:ok, %{result:, requested:, completed:}}`.
  """
  def request(core, instruction, opts \\ []) do
    work_item_id = opts[:work_item_id] || Envelope.generate_id("wi")
    correlation_id = opts[:correlation_id] || Envelope.generate_id("corr")
    timeout = opts[:timeout] || 30_000

    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    try do
      {:ok, requested} =
        EventCore.append(
          core,
          Envelope.command("task.requested",
            correlation_id: correlation_id,
            idempotency_key: opts[:idempotency_key],
            session_id: opts[:session_id],
            project_id: opts[:project_id],
            work_item_id: work_item_id,
            payload: %{instruction: instruction, depth: 0}
          )
        )

      # An idempotent re-submission returns the original command; its work item
      # is the one to wait for (or may already be complete in the log).
      wait_root(core, requested, timeout)
    after
      EventCore.unsubscribe(core)
    end
  end

  @doc "Ask the runtime to start a new attempt for a failed work item."
  def resume(core, work_item_id, opts \\ []) do
    EventCore.append(
      core,
      Envelope.command("task.resumed",
        correlation_id: Keyword.fetch!(opts, :correlation_id),
        causation_id: opts[:causation_id],
        work_item_id: work_item_id,
        payload: %{reason: opts[:reason] || "operator"}
      )
    )
  end

  def runs(runtime), do: GenServer.call(runtime, :runs)

  # --- callbacks ------------------------------------------------------------------

  @impl true
  def init(opts) do
    core = Keyword.fetch!(opts, :core)
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    :ok = EventCore.subscribe(core)

    {:ok,
     %{
       core: core,
       sup: sup,
       agents: Keyword.fetch!(opts, :agents),
       max_depth: Keyword.get(opts, :max_depth, 1),
       run_opts: Keyword.get(opts, :run_opts, []),
       config: normalize_runtime_config(Keyword.get(opts, :config)),
       runs: %{},
       pids: %{},
       handled: MapSet.new(),
       pending_continuations: %{}
     }}
  end

  @impl true
  def handle_call(:runs, _from, state), do: {:reply, state.runs, state}

  @impl true
  def handle_info({:event_core, env}, state) do
    if MapSet.member?(state.handled, env.event_id) do
      {:noreply, state}
    else
      state = %{state | handled: MapSet.put(state.handled, env.event_id)}
      {:noreply, activate(env, state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {run_id, pids} ->
        {run, runs} = Map.pop(state.runs, run_id)
        if reason != :normal, do: record_crash(state.core, run, reason)

        state = %{state | pids: pids, runs: runs}
        {:noreply, maybe_continue_parent(state, run.work_item_id)}
    end
  end

  # --- activation -----------------------------------------------------------------

  defp activate(%Envelope{kind: :command, type: "task.requested"} = env, state) do
    start_run(state, %{
      activation: env,
      work_item_id: env.work_item_id,
      correlation_id: env.correlation_id,
      depth: 0,
      attempt: 1,
      instruction: env.payload["instruction"],
      parent_run_id: nil,
      originating_run_id: nil,
      checkpoint: %{},
      project_id: env.project_id,
      session_id: env.session_id
    })
  end

  defp activate(%Envelope{kind: :event, type: "task.delegated"} = env, state) do
    p = env.payload

    start_run(state, %{
      activation: env,
      work_item_id: p["child_work_item_id"],
      correlation_id: env.correlation_id,
      depth: p["to_depth"],
      attempt: 1,
      instruction: p["instruction"],
      parent_run_id: p["parent_run_id"],
      originating_run_id: p["originating_run_id"],
      checkpoint: %{},
      project_id: env.project_id,
      session_id: env.session_id
    })
  end

  defp activate(%Envelope{kind: :command, type: "task.resumed"} = env, state) do
    case derive_resume(state.core, env.work_item_id) do
      {:ok, spec} ->
        start_run(state, Map.merge(spec, %{activation: env, correlation_id: env.correlation_id}))

      {:error, reason} ->
        EventCore.append!(
          state.core,
          Envelope.event("task.resume_rejected",
            correlation_id: env.correlation_id,
            causation_id: env.event_id,
            work_item_id: env.work_item_id,
            payload: %{reason: inspect(reason)}
          )
        )

        state
    end
  end

  defp activate(%Envelope{type: "task.completed"} = env, state) do
    case find_parent_waiter(state.core, env.work_item_id) do
      {:ok, parent_wi, run_completed} ->
        checkpoint = run_completed.payload["checkpoint"] || %{}
        awaiting = checkpoint["awaiting"] || []
        child_id = to_string(env.work_item_id)

        if child_id in Enum.map(awaiting, &to_string/1) do
          maybe_continue_parent(state, parent_wi, env, run_completed, child_id, awaiting)
        else
          state
        end

      :error ->
        state
    end
  end

  defp activate(%Envelope{type: "run.started"} = env, state) do
    case state.runs[env.run_id] do
      nil ->
        state

      run ->
        %{state | runs: Map.put(state.runs, env.run_id, %{run | started_event_id: env.event_id})}
    end
  end

  defp activate(_env, state), do: state

  defp start_run(state, spec) do
    case resolve_policy(state, spec) do
      {:error, reason} ->
        policy_invalid(state, spec, reason)

      {:ok, agent, bands, policy_hash, request_permission} ->
        start_run_with_agent(state, spec, agent, bands, policy_hash, request_permission)
    end
  end

  defp start_run_with_agent(state, spec, agent, bands, policy_hash, request_permission) do
    run_id = Envelope.generate_id("run")

    opts =
      spec
      |> Map.merge(%{
        core: state.core,
        run_id: run_id,
        agent: agent,
        tools: bands,
        policy_hash: policy_hash,
        request_permission: request_permission,
        max_depth: state.max_depth,
        reason: Map.get(spec, :reason, "initial")
      })
      |> Map.merge(Map.new(state.run_opts))
      |> Map.to_list()

    {:ok, pid} = DynamicSupervisor.start_child(state.sup, {Run, opts})
    ref = Process.monitor(pid)

    run = %{
      pid: pid,
      ref: ref,
      run_id: run_id,
      work_item_id: spec.work_item_id,
      correlation_id: spec.correlation_id,
      activation_id: spec.activation.event_id,
      started_event_id: nil,
      depth: spec.depth,
      attempt: spec.attempt
    }

    %{state | runs: Map.put(state.runs, run_id, run), pids: Map.put(state.pids, pid, run_id)}
  end

  defp resolve_policy(state, spec) do
    case state.config do
      nil -> resolve_policy_without_config(state, spec)
      config -> resolve_policy_with_config(state, spec, config)
    end
  end

  defp resolve_policy_without_config(state, spec) do
    agent = state.agents.(agent_context(state, spec))
    bands = bands_from_tools(agent.tools)
    {:ok, agent, bands, nil, false}
  end

  defp resolve_policy_with_config(state, spec, config) do
    load_opts = [
      cwd: config[:cwd] || File.cwd!(),
      config_file: config[:config_file],
      env: config[:env] || %{}
    ]

    with {:ok, loaded} <- Config.load(load_opts),
         table when is_map(table) <- Policy.table(loaded),
         hash <- Policy.hash(table),
         :ok <- maybe_emit_policy_loaded(state, spec, hash, table),
         profile = config[:profile] || loaded.defaults.preset || "coding",
         workspace = resolve_workspace(spec, loaded),
         depth = to_string(spec.depth),
         {:ok, line_bands} <- Policy.line(table, profile, depth, workspace),
         {:ok, ceiling} <- policy_ceiling(loaded, depth, workspace),
         true <- Policy.fits_ceiling?(line_bands, ceiling),
         {:ok, bands} <- maybe_narrow_tools(config, line_bands) do
      agent = state.agents.(agent_context(state, spec))
      agent = %{agent | tools: bands["granted"]}
      {:ok, agent, bands, hash, negotiable_or_human?(bands)}
    else
      false -> {:error, :profile_outside_ceiling}
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_ceiling(loaded, depth, workspace) do
    catalog_version = loaded.session[:tools_catalog]

    depth_policy = Map.get(loaded.policy, depth, %{})
    workspace_entry = Map.get(loaded.workspaces, workspace, %{})
    workspace_policy = Map.get(workspace_entry, :policy, %{})

    with {:ok, depth_bands} <- Policy.normalize(depth_policy, catalog_version: catalog_version),
         {:ok, workspace_bands} <-
           Policy.normalize(workspace_policy, catalog_version: catalog_version) do
      {:ok, Policy.intersect(depth_bands, workspace_bands)}
    end
  end

  defp maybe_emit_policy_loaded(state, spec, hash, table) do
    last =
      state.core
      |> EventCore.stream(0, type: "policy.loaded")
      |> List.last()

    if last && last.payload["hash"] == hash do
      :ok
    else
      EventCore.append!(
        state.core,
        Envelope.event("policy.loaded",
          correlation_id: spec.correlation_id,
          causation_id: spec.activation.event_id,
          payload: %{hash: hash, table: encode_policy_table(table)}
        )
      )

      :ok
    end
  end

  defp policy_invalid(state, spec, reason) do
    EventCore.append!(
      state.core,
      Envelope.event("run.failed",
        correlation_id: spec.correlation_id,
        causation_id: spec.activation.event_id,
        work_item_id: spec.work_item_id,
        payload: %{reason: "policy_invalid", detail: inspect(reason)}
      )
    )

    state
  end

  defp encode_policy_table(table) do
    table
    |> Enum.map(fn {{profile, depth, workspace}, bands} ->
      %{
        "profile" => profile,
        "depth" => depth,
        "workspace" => workspace,
        "granted" => bands["granted"],
        "negotiable" => bands["negotiable"],
        "human" => bands["human"],
        "forbidden" => bands["forbidden"]
      }
    end)
    |> Enum.sort_by(&{&1["profile"], &1["depth"], &1["workspace"]})
  end

  defp maybe_narrow_tools(config, bands) do
    case config[:tools] do
      nil -> {:ok, bands}
      tools -> Policy.narrow(bands, parse_tools_flag(tools))
    end
  end

  defp parse_tools_flag(tools) when is_list(tools), do: tools

  defp parse_tools_flag(tools) when is_binary(tools) do
    String.split(tools, ",", trim: true)
  end

  defp negotiable_or_human?(bands) do
    (bands["negotiable"] || []) != [] or (bands["human"] || []) != []
  end

  defp resolve_workspace(spec, loaded) do
    Map.get(spec, :workspace) ||
      spec.activation.workspace_id ||
      spec.activation.payload["workspace"] ||
      case Map.keys(loaded.workspaces) do
        [] -> "default"
        [only] -> only
        keys -> Enum.at(keys, 0)
      end
  end

  defp agent_context(state, spec) do
    %{
      depth: spec.depth,
      max_depth: state.max_depth,
      attempt: spec.attempt,
      instruction: spec.instruction,
      checkpoint: spec.checkpoint,
      workspace: Map.get(spec, :workspace, spec.activation.workspace_id),
      team: Map.get(spec, :team, spec.activation.payload["team"]),
      reason: Map.get(spec, :reason, "initial")
    }
  end

  defp bands_from_tools(tools) do
    %{
      "granted" => tools,
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp normalize_runtime_config(nil), do: nil
  defp normalize_runtime_config([]), do: nil

  defp normalize_runtime_config(config) when is_list(config) do
    if Keyword.keyword?(config), do: Map.new(config), else: nil
  end

  defp normalize_runtime_config(config) when is_map(config) do
    if map_size(config) == 0, do: nil, else: config
  end

  defp normalize_runtime_config(_), do: nil

  defp record_crash(core, run, reason) do
    EventCore.append!(
      core,
      Envelope.event("run.failed",
        correlation_id: run.correlation_id,
        causation_id: run.started_event_id || run.activation_id,
        work_item_id: run.work_item_id,
        run_id: run.run_id,
        payload: %{reason: inspect(reason), crashed: true}
      )
    )
  end

  # --- resume derived from the log -------------------------------------------------

  defp derive_resume(core, work_item_id) do
    history = EventCore.stream(core, 0, work_item_id: work_item_id)
    activation = find_activation(core, work_item_id)
    starts = Enum.filter(history, &(&1.type == "run.started"))
    last_start = List.last(starts)

    closed? =
      last_start &&
        Enum.any?(history, &(&1.run_id == last_start.run_id and &1.type in ["run.failed"]))

    completed? = Enum.any?(history, &(&1.type == "task.completed"))

    cond do
      is_nil(activation) ->
        {:error, :unknown_work_item}

      completed? ->
        {:error, :already_completed}

      is_nil(last_start) ->
        {:error, :never_started}

      not closed? ->
        {:error, :run_still_open}

      true ->
        checkpoint =
          history
          |> Enum.filter(&(&1.type == "tool.call.completed" and is_map(&1.payload["checkpoint"])))
          |> List.last()
          |> case do
            nil -> %{}
            env -> atomize_checkpoint(env.payload["checkpoint"])
          end

        p = last_start.payload

        {:ok,
         %{
           work_item_id: work_item_id,
           depth: p["depth"],
           attempt: length(starts) + 1,
           instruction: activation_instruction(activation),
           parent_run_id: p["parent_run_id"],
           originating_run_id: p["originating_run_id"],
           checkpoint: checkpoint,
           project_id: activation.project_id,
           session_id: activation.session_id,
           reason: "retry"
         }}
    end
  end

  defp find_activation(core, work_item_id) do
    case EventCore.stream(core, 0, work_item_id: work_item_id, type: "task.requested", limit: 1) do
      [env] ->
        env

      [] ->
        core
        |> EventCore.stream(0, type: "task.delegated")
        |> Enum.find(&(&1.payload["child_work_item_id"] == work_item_id))
    end
  end

  defp activation_instruction(%Envelope{payload: %{"instruction" => i}}), do: i

  # pending_continuations remains an in-memory queue (phase 4 rebuilds from log).
  defp find_parent_waiter(core, child_work_item_id) do
    child = to_string(child_work_item_id)

    parent_wi =
      case find_parent_in_projection(core, child) do
        {:ok, parent_wi} -> parent_wi
        :error -> parent_work_item_id(core, child)
      end

    with parent_wi when is_binary(parent_wi) <- parent_wi,
         %Envelope{payload: %{"outcome" => "waiting"}} = run_completed <-
           EventCore.stream(core, 0, work_item_id: parent_wi, type: "run.completed")
           |> List.last() do
      {:ok, parent_wi, run_completed}
    else
      _ -> :error
    end
  end

  defp find_parent_in_projection(core, child) do
    waiting_rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE status = ?",
        ["waiting"]
      )

    # Continuation runs flip status to running while awaiting stays on WORK_ITEMS.
    running_rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE status = ? AND awaiting IS NOT NULL AND awaiting != '' AND awaiting != '[]'",
        ["running"]
      )

    case Enum.find(waiting_rows ++ running_rows, fn [_parent_wi, awaiting] ->
           case decode_awaiting(awaiting) do
             ids when is_list(ids) -> child in Enum.map(ids, &to_string/1)
             _ -> false
           end
         end) do
      [parent_wi, _] -> {:ok, parent_wi}
      nil -> :error
    end
  end

  defp parent_work_item_id(core, child) do
    case EventCore.query(
           core,
           "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?",
           [child]
         ) do
      [[parent_wi]] when is_binary(parent_wi) -> parent_wi
      _ -> nil
    end
  end

  defp decode_awaiting(nil), do: nil
  defp decode_awaiting(""), do: nil
  defp decode_awaiting(ids) when is_list(ids), do: ids

  defp decode_awaiting(json) when is_binary(json) do
    Jason.decode!(json)
  end

  defp continue_parent(state, env, parent_wi, checkpoint, child_id, awaiting) do
    pending = checkpoint["pending"] || %{}

    tool_call_id =
      pending[child_id] ||
        pending[env.work_item_id] ||
        pending |> Map.values() |> List.first() ||
        "call_delegate"

    new_awaiting = Enum.reject(awaiting, &(to_string(&1) == child_id))

    pending_text =
      case new_awaiting do
        [] -> "none"
        ids -> Enum.map_join(ids, ", ", &to_string/1)
      end

    observation = %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" =>
        "Sub-agent completed. Result: #{env.payload["result"]}. Still pending: #{pending_text}"
    }

    new_pending =
      pending
      |> Map.delete(child_id)
      |> Map.delete(env.work_item_id)

    new_checkpoint =
      checkpoint
      |> Map.put("messages", (checkpoint["messages"] || []) ++ [observation])
      |> Map.put("awaiting", new_awaiting)
      |> Map.put("pending", new_pending)

    last_start =
      EventCore.stream(state.core, 0, work_item_id: parent_wi, type: "run.started")
      |> List.last()

    attempt =
      EventCore.stream(state.core, 0, work_item_id: parent_wi, type: "run.started")
      |> length()
      |> Kernel.+(1)

    activation = find_activation(state.core, parent_wi)

    start_run(state, %{
      activation: env,
      work_item_id: parent_wi,
      correlation_id: env.correlation_id,
      depth: last_start.payload["depth"],
      attempt: attempt,
      instruction: activation_instruction(activation),
      parent_run_id: last_start.payload["parent_run_id"],
      originating_run_id: last_start.payload["originating_run_id"],
      checkpoint: new_checkpoint,
      project_id: env.project_id,
      session_id: env.session_id,
      reason: "continuation"
    })
  end

  defp live_run_for_work_item?(state, work_item_id) do
    Enum.any?(state.runs, fn {_, run} -> run.work_item_id == work_item_id end)
  end

  defp queue_continuation(state, parent_wi, env) do
    queue = Map.get(state.pending_continuations, parent_wi, [])

    %{
      state
      | pending_continuations: Map.put(state.pending_continuations, parent_wi, queue ++ [env])
    }
  end

  defp maybe_continue_parent(
         state,
         work_item_id,
         env \\ nil,
         run_completed \\ nil,
         child_id \\ nil,
         awaiting \\ nil
       ) do
    cond do
      env ->
        if live_run_for_work_item?(state, work_item_id) do
          queue_continuation(state, work_item_id, env)
        else
          continue_parent(
            state,
            env,
            work_item_id,
            run_completed.payload["checkpoint"] || %{},
            child_id,
            awaiting
          )
        end

      true ->
        case Map.get(state.pending_continuations, work_item_id, []) do
          [] ->
            state

          [next | rest] ->
            pending =
              if rest == [],
                do: Map.delete(state.pending_continuations, work_item_id),
                else: Map.put(state.pending_continuations, work_item_id, rest)

            state = %{state | pending_continuations: pending}

            case find_parent_waiter(state.core, next.work_item_id) do
              {:ok, parent_wi, run_completed} ->
                checkpoint = run_completed.payload["checkpoint"] || %{}
                awaiting = checkpoint["awaiting"] || []
                child_id = to_string(next.work_item_id)

                if child_id in Enum.map(awaiting, &to_string/1) do
                  maybe_continue_parent(state, parent_wi, next, run_completed, child_id, awaiting)
                else
                  state
                end

              :error ->
                state
            end
        end
    end
  end

  # Tool state is kept with atom keys in memory (see Tools.Counter); the log
  # stores it as JSON.
  defp atomize_checkpoint(map) when is_map(map) do
    Map.new(map, fn {tool, state} ->
      {tool, Map.new(state, fn {k, v} -> {String.to_atom(k), v} end)}
    end)
  end

  # --- root wait ---------------------------------------------------------------------

  defp wait_root(core, requested, timeout) do
    already =
      core
      |> EventCore.stream(0,
        work_item_id: requested.work_item_id,
        type: "task.completed",
        limit: 1
      )
      |> List.first()

    completed =
      case already do
        %Envelope{} = env ->
          {:ok, env}

        nil ->
          wid = requested.work_item_id

          receive do
            {:event_core, %Envelope{type: "task.completed", work_item_id: ^wid} = env} ->
              {:ok, env}
          after
            timeout -> {:error, :timeout}
          end
      end

    case completed do
      {:ok, env} ->
        {:ok, %{result: env.payload["result"], requested: requested, completed: env}}

      {:error, _} = err ->
        err
    end
  end
end
