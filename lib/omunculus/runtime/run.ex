defmodule Omunculus.Runtime.Run do
  @moduledoc """
  One durable attempt (Run) of an Execution Node executing a Work Item
  (docs/to-be/execution-model.md).

  The process is an ephemeral Session: it is not the source of truth. Every
  transition goes through the Event Core and the process only continues after
  the corresponding envelope has been committed **and delivered back** to it,
  which is the flow drawn in the `conte até 10` scenarios of event-model.md:

      tool.call.requested -> append+commit -> deliver -> execute
      tool.call.completed -> append+commit -> deliver -> next round

  Delegation appends `task.delegated`, then blocks until the child's
  `task.completed` is delivered. The causation chain follows the scenario
  table exactly; `run.*` and `model.call.*` hang off the chain as side
  branches so the documented chain is preserved.
  """

  use GenServer, restart: :temporary

  alias Omunculus.{Agent, EventCore, FS, Tools}
  alias Omunculus.Event.Envelope
  alias Omunculus.Tool.Context

  @delivery_timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = Map.new(opts)
    :ok = EventCore.subscribe(state.core, correlation_id: state.correlation_id)
    {:ok, state, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state) do
    activation = state.activation
    Process.put(:chain_head, activation.event_id)
    Process.put(:tool_round, 0)

    started =
      append!(state, :event, "run.started", %{
        attempt: state.attempt,
        depth: state.depth,
        parent_run_id: state.parent_run_id,
        originating_run_id: state.originating_run_id,
        agent_id: state.agent.agent_id,
        agent_kind: state.agent.kind,
        checkpoint: state.checkpoint
      })

    Process.put(:run_started_id, started.event_id)

    agent = state.agent

    outcome =
      Agent.run(
        instruction: state.instruction,
        chat: agent.chat,
        fs: state[:fs] || FS.Memory.new(%{}),
        tools: agent.tools,
        max_turns: agent[:max_turns] || 32,
        instructions: agent[:instructions],
        system_prompt: agent[:system_prompt],
        nudge: agent[:nudge],
        tool_options: agent[:tool_options] || %{},
        tool_state: state.checkpoint,
        tool_executor: &execute_tool(state, &1, &2, &3, &4),
        reporter: &report(state, &1)
      )

    case outcome do
      {:ok, result} ->
        completed =
          append!(state, :event, "task.completed", %{
            result: result.assistant_text,
            depth: state.depth,
            rounds: result.turns,
            tool_calls: result.tool_calls
          })

        append!(
          state,
          :event,
          "run.completed",
          %{rounds: result.turns, tool_calls: result.tool_calls, usage: result.usage},
          completed.event_id
        )

        {:stop, :normal, state}

      {:error, reason} ->
        append!(state, :event, "run.failed", %{reason: inspect(reason)})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:event_core, _env}, state), do: {:noreply, state}

  # --- tool execution through the core -------------------------------------------

  defp execute_tool(state, "delegate", args, context, active) do
    if "delegate" in active, do: delegate(state, args, context), else: {:error, :denied, context}
  end

  defp execute_tool(state, name, args, context, active) do
    round = Process.get(:tool_round) + 1
    Process.put(:tool_round, round)

    requested =
      append!(state, :event, "tool.call.requested", %{
        tool: name,
        args: args,
        round: round,
        counter: counter_payload(name, context)
      })

    await_delivery(requested.event_id)

    {body, context, outcome} =
      case Tools.call_context(name, args, context, active) do
        {:ok, output, context} ->
          {output, context, "completed"}

        {:error, reason, context} ->
          {"error: #{inspect(reason)}", context, "error:#{inspect(reason)}"}
      end

    completed =
      append!(
        state,
        :event,
        "tool.call.completed",
        %{
          tool: name,
          round: round,
          outcome: outcome,
          previous: counter_value(name, Context.tool_state(context, name, nil), :previous),
          new: counter_value(name, Context.tool_state(context, name, nil), :new),
          checkpoint: checkpoint(context)
        },
        requested.event_id
      )

    await_delivery(completed.event_id)
    Process.put(:chain_head, completed.event_id)

    if outcome == "completed", do: {:ok, body, context}, else: {:error, outcome, context}
  end

  defp delegate(state, args, context) do
    if state.depth >= state.max_depth do
      {:error, :max_depth_exceeded, context}
    else
      child = Envelope.generate_id("wi")
      instruction = args["instruction"] || args[:instruction] || state.instruction

      delegated =
        append!(state, :event, "task.delegated", %{
          instruction: instruction,
          child_work_item_id: child,
          to_depth: state.depth + 1,
          parent_run_id: state.run_id,
          originating_run_id: state.originating_run_id || state.run_id
        })

      await_delivery(delegated.event_id)

      case await_child(child, state[:delegation_timeout] || 60_000) do
        {:ok, completed} ->
          Process.put(:chain_head, completed.event_id)
          {:ok, "Sub-agent completed. Result: #{completed.payload["result"]}", context}

        {:error, reason} ->
          {:error, reason, context}
      end
    end
  end

  defp await_delivery(event_id) do
    receive do
      {:event_core, %Envelope{event_id: ^event_id}} -> :ok
    after
      @delivery_timeout -> raise "event #{event_id} was committed but never delivered"
    end
  end

  defp await_child(child_work_item_id, timeout) do
    receive do
      {:event_core, %Envelope{type: "task.completed", work_item_id: ^child_work_item_id} = env} ->
        {:ok, env}
    after
      timeout -> {:error, {:delegation_timeout, child_work_item_id}}
    end
  end

  # --- side branches --------------------------------------------------------------

  defp report(state, %{type: :round_completed} = ev) do
    append!(
      state,
      :event,
      "model.call.completed",
      %{
        round: ev.round,
        outcome: ev.outcome,
        usage: ev.usage,
        duration_ms: ev.duration_ms,
        model: state.agent[:model]
      },
      Process.get(:run_started_id)
    )

    :ok
  end

  defp report(_state, _ev), do: :ok

  # --- helpers ---------------------------------------------------------------------

  defp append!(state, kind, type, payload, causation_id \\ nil) do
    env =
      Envelope.new(kind, type,
        correlation_id: state.correlation_id,
        causation_id: causation_id || Process.get(:chain_head),
        session_id: state[:session_id],
        workspace_id: state[:workspace_id],
        project_id: state[:project_id],
        work_item_id: state.work_item_id,
        run_id: state.run_id,
        payload: payload
      )

    EventCore.append!(state.core, env)
  end

  defp checkpoint(%Context{state: tool_state}) when map_size(tool_state) == 0, do: nil
  defp checkpoint(%Context{state: tool_state}), do: tool_state

  defp counter_payload("counter", context) do
    options = Context.tool_options(context, "counter")
    %{increment: options[:increment] || options["increment"] || 1}
  end

  defp counter_payload(_name, _context), do: nil

  defp counter_value("counter", %{value: value, increment: inc}, :previous), do: value - inc
  defp counter_value("counter", %{value: value}, :new), do: value
  defp counter_value(_name, _state, _which), do: nil
end
