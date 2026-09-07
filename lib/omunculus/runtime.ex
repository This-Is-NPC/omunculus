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
    run_id = Envelope.generate_id("run")
    workspace = Map.get(spec, :workspace, spec.activation.workspace_id)
    team = Map.get(spec, :team, spec.activation.payload["team"])

    agent =
      state.agents.(%{
        depth: spec.depth,
        max_depth: state.max_depth,
        attempt: spec.attempt,
        instruction: spec.instruction,
        checkpoint: spec.checkpoint,
        workspace: workspace,
        team: team,
        reason: Map.get(spec, :reason, "initial")
      })

    opts =
      spec
      |> Map.merge(%{
        core: state.core,
        run_id: run_id,
        agent: agent,
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

  defp find_parent_waiter(core, child_work_item_id) do
    child = to_string(child_work_item_id)

    case Enum.find(EventCore.stream(core, 0, type: "task.delegated"), fn env ->
           to_string(env.payload["child_work_item_id"]) == child
         end) do
      nil ->
        :error

      delegated ->
        parent_wi = delegated.work_item_id

        case EventCore.stream(core, 0, work_item_id: parent_wi, type: "run.completed")
             |> List.last() do
          %Envelope{payload: %{"outcome" => "waiting"}} = run_completed ->
            {:ok, parent_wi, run_completed}

          _ ->
            :error
        end
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
