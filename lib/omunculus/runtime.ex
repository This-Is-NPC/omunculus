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

    payload =
      %{instruction: instruction, depth: 0}
      |> maybe_put_workspace_payload(opts[:workspace])

    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    try do
      {:ok, requested} =
        EventCore.append(
          core,
          Envelope.command("task.requested",
            correlation_id: correlation_id,
            idempotency_key: opts[:idempotency_key],
            session_id: opts[:session_id],
            workspace_id: opts[:workspace_id],
            project_id: opts[:project_id],
            work_item_id: work_item_id,
            payload: payload
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

    state =
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
        pending_continuations: %{},
        nodes: %{}
      }

    state = rebuild_pending_continuations(state)
    state = flush_pending_continuations(state)

    {:ok, state}
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
      session_id: env.session_id,
      workspace_id: nil,
      workspace: env.payload["workspace"]
    })
  end

  defp activate(%Envelope{kind: :event, type: "task.delegated"} = env, state) do
    p = env.payload
    depth = p["to_depth"]
    workspace = p["workspace"] || env.workspace_id

    start_run(state, %{
      activation: env,
      work_item_id: p["child_work_item_id"],
      correlation_id: env.correlation_id,
      depth: depth,
      attempt: 1,
      instruction: p["instruction"],
      parent_run_id: p["parent_run_id"],
      originating_run_id: p["originating_run_id"],
      checkpoint: %{},
      project_id: env.project_id,
      session_id: env.session_id,
      workspace: workspace,
      workspace_id: if(depth > 0, do: workspace, else: nil),
      team: p["team"],
      agent: p["agent"]
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

  defp activate(%Envelope{type: "workspace.attached"} = env, state) do
    register_attached_nodes(state, env)
  end

  defp activate(%Envelope{type: "workspace.detached"} = env, state) do
    fail_runs_in_workspace(state, env.payload["workspace_id"])
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

      {:ok, agent, bands, policy_hash, request_permission, spec, state} ->
        spec = maybe_prepend_comments(state, spec, agent)
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
      attempt: spec.attempt,
      workspace_id: Map.get(spec, :workspace_id) || Map.get(spec, :workspace)
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
    workspace = Map.get(spec, :workspace) || spec.activation.payload["workspace"]

    roots =
      case attached_workspace_row(state.core, workspace) do
        {:ok, attached_roots, _} -> attached_roots
        :error -> Map.get(spec, :roots, [])
      end

    spec = Map.put(spec, :roots, roots)
    {spec, state} = assign_node_id(state, spec, nil)
    agent = state.agents.(agent_context(state, spec))

    agent =
      merge_config_tool_options(agent, %{workspaces: %{}, teams: %{}, agents: %{}}, spec, state)

    bands = bands_from_tools(agent.tools)
    {:ok, agent, bands, nil, false, spec, state}
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
         profile = resolve_profile(spec, loaded, config),
         workspace = resolve_workspace(spec, loaded, state),
         depth = to_string(spec.depth),
         {:ok, line_bands} <- Policy.line(table, profile, depth, workspace),
         {:ok, ceiling} <- policy_ceiling(loaded, depth, workspace),
         true <- Policy.fits_ceiling?(line_bands, ceiling),
         {:ok, narrow_bands} <- maybe_intersect_team_profile(loaded, spec, line_bands),
         {:ok, bands} <- maybe_narrow_tools(config, narrow_bands) do
      roots = workspace_roots(state, workspace, loaded)

      spec =
        spec
        |> Map.put(:workspace, workspace)
        |> Map.put(:workspace_id, envelope_workspace_id(spec, workspace))
        |> Map.put(:roots, roots)
        |> Map.put(:session_id, spec.session_id || spec.activation.session_id)

      {spec, state} = assign_node_id(state, spec, loaded)
      agent = state.agents.(agent_context(state, spec, loaded))
      agent = %{agent | tools: bands["granted"]}
      agent = merge_config_tool_options(agent, loaded, spec, state)
      {:ok, agent, bands, hash, negotiable_or_human?(bands), spec, state}
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

  defp resolve_workspace(spec, loaded, state) do
    explicit =
      Map.get(spec, :workspace) ||
        spec.activation.workspace_id ||
        spec.activation.payload["workspace"]

    if explicit do
      explicit
    else
      attached = session_workspaces(state, spec)

      cond do
        attached != [] ->
          Enum.at(attached, 0)

        Map.has_key?(loaded.workspaces, "app") ->
          "app"

        true ->
          case Map.keys(loaded.workspaces) do
            [] -> "default"
            [only] -> only
            keys -> Enum.at(keys, 0)
          end
      end
    end
  end

  defp envelope_workspace_id(spec, policy_workspace) do
    if spec.depth == 0 do
      nil
    else
      Map.get(spec, :workspace_id) ||
        Map.get(spec, :workspace) ||
        spec.activation.workspace_id ||
        spec.activation.payload["workspace"] ||
        policy_workspace
    end
  end

  defp agent_context(state, spec, loaded \\ nil) do
    base = %{
      depth: spec.depth,
      max_depth: state.max_depth,
      attempt: spec.attempt,
      instruction: spec.instruction,
      checkpoint: spec.checkpoint,
      session_id: spec.session_id || spec.activation.session_id,
      workspace_id: envelope_workspace_id(spec, Map.get(spec, :workspace)),
      workspace: Map.get(spec, :workspace, spec.activation.workspace_id),
      team: Map.get(spec, :team, spec.activation.payload["team"]),
      agent: Map.get(spec, :agent, spec.activation.payload["agent"]),
      reason: Map.get(spec, :reason, "initial")
    }

    case loaded do
      nil ->
        base

      config ->
        base
        |> Map.put(:config, config)
        |> Map.put(:profile, resolve_profile(spec, config, state.config))
    end
  end

  defp resolve_profile(_spec, loaded, config) do
    config[:profile] || loaded.defaults.preset || "coding"
  end

  defp maybe_intersect_team_profile(loaded, spec, line_bands) do
    team_name = Map.get(spec, :team) || spec.activation.payload["team"]

    with name when is_binary(name) <- team_name,
         %{profile: team_profile} <- Map.get(loaded.teams, name, %{}),
         true <- is_binary(team_profile) and Map.has_key?(loaded.presets, team_profile),
         preset <- Map.get(loaded.presets, team_profile),
         {:ok, team_bands} <-
           Policy.normalize(preset[:policy] || %{},
             catalog_version: loaded.session[:tools_catalog]
           ) do
      {:ok, Policy.intersect(line_bands, team_bands)}
    else
      _ -> {:ok, line_bands}
    end
  end

  defp merge_config_tool_options(agent, loaded, spec, state) do
    workspaces =
      if spec.depth == 0 do
        attached_workspaces_snapshot(state, loaded) || loaded.workspaces
      else
        loaded.workspaces
      end

    snapshot = %{
      workspaces: workspaces,
      teams: loaded.teams,
      agents: loaded.agents
    }

    tool_options = Map.merge(Map.get(agent, :tool_options) || %{}, snapshot)

    tool_options =
      case Map.get(spec, :roots) do
        roots when is_list(roots) and roots != [] -> Map.put(tool_options, :roots, roots)
        _ -> tool_options
      end

    Map.put(agent, :tool_options, tool_options)
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

  defp maybe_prepend_comments(state, %{depth: 0} = spec, agent) do
    session_id = spec.session_id || spec.activation.session_id
    checkpoint = spec.checkpoint || %{}

    with true <- is_binary(session_id) and session_id != "",
         true <- checkpoint == %{} or checkpoint_messages_empty?(checkpoint),
         comments when comments != [] <- session_comments(state.core, session_id) do
      note = format_session_comments(comments)

      messages = [
        %{"role" => "system", "content" => agent[:system_prompt] || ""},
        %{"role" => "user", "content" => note},
        %{"role" => "user", "content" => spec.instruction}
      ]

      %{spec | checkpoint: Map.put(checkpoint, "messages", messages)}
    else
      _ -> spec
    end
  end

  defp maybe_prepend_comments(_state, spec, _agent), do: spec

  defp checkpoint_messages_empty?(checkpoint) do
    case Map.get(checkpoint, "messages") || Map.get(checkpoint, :messages) do
      msgs when is_list(msgs) -> msgs == []
      _ -> true
    end
  end

  defp session_comments(core, session_id) do
    EventCore.query(
      core,
      "SELECT kind, body FROM COMMENTS WHERE session_id = ? ORDER BY last_sequence DESC LIMIT 10",
      [session_id]
    )
  rescue
    _ -> []
  end

  defp format_session_comments(comments) do
    lines =
      Enum.map(comments, fn [kind, body] ->
        "#{kind}: #{body}"
      end)

    "Recent session comments:\n" <> Enum.join(lines, "\n")
  end

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
           workspace: p["workspace"] || activation.payload["workspace"],
           workspace_id:
             if(p["depth"] > 0, do: p["workspace"] || activation.workspace_id, else: nil),
           node_id: p["node_id"],
           team: p["team"],
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

  # pending_continuations is rebuilt from WORK_ITEMS on init (see rebuild_pending_continuations/1).
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
    case Jason.decode(json) do
      {:ok, ids} -> ids
      _ -> nil
    end
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
      workspace: last_start.payload["workspace"],
      workspace_id:
        if(last_start.payload["depth"] > 0,
          do: last_start.payload["workspace"] || env.workspace_id,
          else: nil
        ),
      node_id: last_start.payload["node_id"],
      team: last_start.payload["team"],
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

  defp maybe_put_workspace_payload(payload, nil), do: payload

  defp maybe_put_workspace_payload(payload, workspace),
    do: Map.put(payload, :workspace, workspace)

  defp session_workspaces(state, spec) do
    session_id = spec.session_id || spec.activation.session_id

    if is_binary(session_id) and match?(%{core: _}, state) do
      attached_session_workspaces(state.core, session_id)
    else
      []
    end
  end

  defp attached_session_workspaces(core, session_id) do
    with true <- projection_table?(core, "SESSION_WORKSPACES"),
         {:ok, sql, args} <- session_workspaces_query(core, session_id),
         rows when is_list(rows) <- safe_event_core_query(core, sql, args) do
      Enum.flat_map(rows, fn
        [ws] when is_binary(ws) -> [ws]
        _ -> []
      end)
    else
      _ -> []
    end
  end

  defp projection_table?(core, table) do
    case safe_event_core_query(
           core,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
           [table]
         ) do
      [[1]] -> true
      _ -> false
    end
  end

  defp session_workspaces_query(core, session_id) do
    case safe_event_core_query(core, "PRAGMA table_info(SESSION_WORKSPACES)", []) do
      rows when is_list(rows) ->
        columns = Enum.map(rows, fn row -> Enum.at(row, 1) end)

        if "session_id" in columns do
          {:ok,
           "SELECT workspace_id FROM SESSION_WORKSPACES WHERE session_id = ? AND attached = 1 ORDER BY workspace_id",
           [session_id]}
        else
          {:ok,
           "SELECT workspace_id FROM SESSION_WORKSPACES WHERE attached = 1 ORDER BY workspace_id",
           []}
        end

      _ ->
        :error
    end
  end

  defp safe_event_core_query(core, sql, args) do
    try do
      EventCore.query(core, sql, args)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp assign_node_id(state, spec, loaded) do
    node_id =
      Map.get(spec, :node_id) ||
        node_id_from_last_start(state, spec) ||
        compute_node_id(spec, loaded)

    key = node_cache_key(spec, loaded)
    nodes = if key, do: Map.put(state.nodes, key, node_id), else: state.nodes
    {Map.put(spec, :node_id, node_id), %{state | nodes: nodes}}
  end

  defp node_id_from_last_start(state, spec) do
    case EventCore.stream(state.core, 0, work_item_id: spec.work_item_id, type: "run.started")
         |> List.last() do
      %Envelope{payload: %{"node_id" => node_id}} when is_binary(node_id) -> node_id
      _ -> nil
    end
  end

  defp compute_node_id(spec, loaded) do
    session_id = spec.session_id || spec.activation.session_id

    case spec.depth do
      0 ->
        hash_node_id([session_id, 0])

      1 ->
        workspace = Map.get(spec, :workspace) || spec.activation.workspace_id
        team = Map.get(spec, :team) || spec.activation.payload["team"]

        if team_scope_node?(loaded, team),
          do: hash_node_id([session_id, workspace, team, 1]),
          else: hash_node_id([session_id, workspace, 1])

      _ ->
        Envelope.generate_id("node")
    end
  end

  defp node_cache_key(spec, loaded) do
    session_id = spec.session_id || spec.activation.session_id

    case spec.depth do
      0 ->
        {:depth0, session_id}

      1 ->
        workspace = Map.get(spec, :workspace) || spec.activation.workspace_id
        team = Map.get(spec, :team) || spec.activation.payload["team"]

        if team_scope_node?(loaded, team),
          do: {:depth1, session_id, workspace, team},
          else: {:depth1, session_id, workspace}

      _ ->
        {:depthn, spec.work_item_id}
    end
  end

  defp team_scope_node?(loaded, team) when is_binary(team) do
    case loaded do
      %{teams: teams} ->
        case Map.get(teams, team, %{}) do
          %{scope: "node"} -> true
          %{"scope" => "node"} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp team_scope_node?(_, _), do: false

  defp hash_node_id(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("node_" <> String.slice(&1, 0, 16)))
  end

  defp rebuild_pending_continuations(state) do
    waiting_rows =
      EventCore.query(
        state.core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE status = ?",
        ["waiting"]
      )

    pending =
      Enum.reduce(waiting_rows, %{}, fn [parent_wi, awaiting_json], acc ->
        with ids when is_list(ids) <- decode_awaiting(awaiting_json),
             %Envelope{payload: %{"outcome" => "waiting"}} = run_completed <-
               EventCore.stream(state.core, 0, work_item_id: parent_wi, type: "run.completed")
               |> List.last(),
             checkpoint_awaiting <- run_completed.payload["checkpoint"]["awaiting"] || [] do
          Enum.reduce(ids, acc, fn child_id, inner ->
            child = to_string(child_id)

            if child in Enum.map(checkpoint_awaiting, &to_string/1) and
                 task_completed?(state.core, child) do
              case EventCore.stream(state.core, 0, work_item_id: child, type: "task.completed")
                   |> List.last() do
                %Envelope{} = env -> Map.update(inner, parent_wi, [env], &(&1 ++ [env]))
                _ -> inner
              end
            else
              inner
            end
          end)
        else
          _ -> acc
        end
      end)

    %{state | pending_continuations: pending}
  end

  defp task_completed?(core, work_item_id) do
    match?(
      [%Envelope{}],
      EventCore.stream(core, 0, work_item_id: work_item_id, type: "task.completed", limit: 1)
    )
  end

  defp flush_pending_continuations(state) do
    Enum.reduce(Map.keys(state.pending_continuations), state, fn parent_wi, acc ->
      maybe_continue_parent(acc, parent_wi)
    end)
  end

  defp register_attached_nodes(state, env) do
    session_id = env.session_id
    workspace_id = env.payload["workspace_id"]

    if is_binary(session_id) and is_binary(workspace_id) do
      loaded = loaded_config(state)
      key = {:depth1, session_id, workspace_id}
      nodes = Map.put(state.nodes, key, hash_node_id([session_id, workspace_id, 1]))

      nodes =
        Enum.reduce(node_scoped_teams(env, loaded, workspace_id), nodes, fn team, acc ->
          Map.put(
            acc,
            {:depth1, session_id, workspace_id, team},
            hash_node_id([session_id, workspace_id, team, 1])
          )
        end)

      %{state | nodes: nodes}
    else
      state
    end
  end

  defp fail_runs_in_workspace(state, workspace_id) when is_binary(workspace_id) do
    Enum.reduce(state.runs, state, fn {_run_id, run}, acc ->
      if run.workspace_id == workspace_id do
        terminate_and_fail_run(acc, run, "detached")
      else
        acc
      end
    end)
  end

  defp fail_runs_in_workspace(state, _workspace_id), do: state

  defp terminate_and_fail_run(state, run, reason) do
    if Process.alive?(run.pid), do: DynamicSupervisor.terminate_child(state.sup, run.pid)

    record_run_failed(state.core, run, reason)

    runs = Map.delete(state.runs, run.run_id)
    pids = Map.delete(state.pids, run.pid)
    %{state | runs: runs, pids: pids}
  end

  defp record_run_failed(core, run, reason) do
    EventCore.append!(
      core,
      Envelope.event("run.failed",
        correlation_id: run.correlation_id,
        causation_id: run.started_event_id || run.activation_id,
        work_item_id: run.work_item_id,
        run_id: run.run_id,
        workspace_id: run.workspace_id,
        payload: %{reason: reason}
      )
    )
  end

  defp workspace_roots(state, workspace, loaded) do
    case attached_workspace_row(state.core, workspace) do
      {:ok, roots, _teams} ->
        roots

      :error ->
        entry = Map.get(loaded.workspaces, workspace, %{})
        entry[:roots] || entry["roots"] || []
    end
  end

  defp attached_workspaces_snapshot(state, loaded) do
    case attached_workspace_rows(state.core) do
      [] ->
        nil

      rows ->
        Map.new(rows, fn {ws_id, roots, teams} ->
          base = Map.get(loaded.workspaces, ws_id, %{})

          entry =
            base
            |> Map.put(:roots, roots)
            |> Map.put(:teams, teams)

          {ws_id, entry}
        end)
    end
  end

  defp attached_workspace_row(core, workspace_id) do
    case Enum.find(attached_workspace_rows(core), fn {ws_id, _, _} -> ws_id == workspace_id end) do
      {_ws_id, roots, teams} -> {:ok, roots, teams}
      nil -> :error
    end
  end

  defp attached_workspace_rows(core) do
    unless projection_table?(core, "SESSION_WORKSPACES"), do: []

    EventCore.query(
      core,
      "SELECT workspace_id, roots, teams FROM SESSION_WORKSPACES WHERE attached = 1 ORDER BY workspace_id",
      []
    )
    |> Enum.flat_map(fn
      [ws_id, roots_json, teams_json] ->
        [{ws_id, decode_json_list(roots_json), decode_json_list(teams_json)}]

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp decode_json_list(nil), do: []

  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(list) when is_list(list), do: list
  defp decode_json_list(_), do: []

  defp node_scoped_teams(env, loaded, workspace_id) do
    teams =
      env.payload["teams"] ||
        case loaded do
          %{workspaces: workspaces} ->
            case Map.get(workspaces, workspace_id, %{}) do
              %{teams: teams} -> teams
              %{"teams" => teams} -> teams
              _ -> []
            end

          _ ->
            []
        end

    Enum.filter(List.wrap(teams), &team_scope_node?(loaded, &1))
  end

  defp loaded_config(state) do
    case state.config do
      nil ->
        nil

      config ->
        load_opts = [
          cwd: config[:cwd] || File.cwd!(),
          config_file: config[:config_file],
          env: config[:env] || %{}
        ]

        case Config.load(load_opts) do
          {:ok, loaded} -> loaded
          _ -> nil
        end
    end
  end
end
