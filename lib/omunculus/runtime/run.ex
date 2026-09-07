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

  Delegation appends `task.delegated` and returns `{:wait, ...}` so the run
  can close with `run.completed` outcome `waiting`. A continuation run resumes
  from the checkpoint when children finish; `run.*` and `model.call.*` hang
  off the chain as side branches so the documented chain is preserved.
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
    Process.put(:awaiting_children, [])

    checkpoint = state.checkpoint || %{}
    reason = state[:reason] || state["reason"] || "initial"

    tools_bands = state[:tools] || bands_from_agent(state.agent)

    started =
      append!(
        state,
        :event,
        "run.started",
        %{
          attempt: state.attempt,
          depth: state.depth,
          parent_run_id: state.parent_run_id,
          originating_run_id: state.originating_run_id,
          agent_id: state.agent.agent_id,
          agent_kind: state.agent.kind,
          reason: reason,
          checkpoint: checkpoint,
          tools: tools_bands
        }
        |> maybe_put_policy_hash(state[:policy_hash])
      )

    Process.put(:run_started_id, started.event_id)

    run_agent(state, checkpoint)
  end

  defp run_agent(state, checkpoint) do
    remaining = checkpoint_awaiting(checkpoint)
    remaining_pending = fetch_key(checkpoint, "pending") || %{}
    agent = state.agent

    opts = [
      instruction: state.instruction,
      chat: agent.chat,
      fs: state[:fs] || FS.Memory.new(%{}),
      tools: agent.tools,
      max_turns: agent[:max_turns] || 32,
      instructions: agent[:instructions],
      system_prompt: agent[:system_prompt],
      nudge: agent[:nudge],
      tool_options: agent[:tool_options] || %{},
      tool_state: tool_state_from(checkpoint),
      tool_executor: &execute_tool(state, &1, &2, &3, &4),
      reporter: &report(state, &1),
      request_permission: state[:request_permission] || agent[:request_permission]
    ]

    opts =
      case checkpoint_messages(checkpoint) do
        messages when is_list(messages) -> Keyword.put(opts, :messages, messages)
        _ -> opts
      end

    outcome = Agent.run(opts)
    new_children = Process.get(:awaiting_children, [])

    case outcome do
      {:waiting, result} ->
        pending =
          Map.merge(remaining_pending, pending_from_messages(result.messages, new_children))

        finish_waiting(state, result, remaining ++ new_children, pending: pending)

      {:ok, result} when remaining != [] ->
        finish_waiting(state, result, remaining,
          pending: remaining_pending,
          notes: result.assistant_text
        )

      {:ok, result} ->
        finish_completed(state, result)

      {:error, reason} ->
        append!(state, :event, "run.failed", %{reason: inspect(reason)})
        {:stop, :normal, state}
    end
  end

  defp finish_waiting(state, result, awaiting, opts) do
    pending = Keyword.fetch!(opts, :pending)

    checkpoint =
      %{
        "messages" => result.messages,
        "tool_state" => result.tool_state,
        "awaiting" => awaiting,
        "pending" => pending
      }
      |> maybe_put_notes(Keyword.get(opts, :notes))

    append!(
      state,
      :event,
      "run.completed",
      %{outcome: "waiting", awaiting: awaiting, checkpoint: checkpoint},
      Process.get(:chain_head)
    )

    {:stop, :normal, state}
  end

  defp finish_completed(state, result) do
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
      %{
        outcome: "completed",
        awaiting: [],
        rounds: result.turns,
        tool_calls: result.tool_calls,
        usage: result.usage
      },
      completed.event_id
    )

    {:stop, :normal, state}
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

    case await_delivery_or_rejection(requested.event_id) do
      :ok ->
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

      {:rejected, rejection} ->
        Process.put(:chain_head, rejection.event_id)
        {:error, {:delivery_rejected, rejection.payload["reason"]}, context}
    end
  end

  # Depth policy is not the node's business: a configured DepthGate
  # interceptor may reject the delivery of task.delegated, in which case the
  # child never starts and the rejection comes back to the model as a tool
  # error, with delivery.rejected as the new head of the causation chain.
  defp delegate(state, args, context) do
    child = Envelope.generate_id("wi")
    instruction = args["instruction"] || args[:instruction] || state.instruction

    delegated =
      append!(state, :event, "task.delegated", %{
        instruction: instruction,
        child_work_item_id: child,
        to_depth: state.depth + 1,
        parent_run_id: state.run_id,
        originating_run_id: state.originating_run_id || state.run_id,
        tools: tools_pin(state)
      })

    case await_delivery_or_rejection(delegated.event_id) do
      :ok ->
        children = Process.get(:awaiting_children, [])
        Process.put(:awaiting_children, children ++ [child])
        {:wait, "delegated", context}

      {:rejected, rejection} ->
        Process.put(:chain_head, rejection.event_id)
        {:error, {:delegation_rejected, rejection.payload["reason"]}, context}
    end
  end

  # A delegation is either delivered back to us or rejected by the lane; the
  # rejection carries causation to the envelope we appended.
  defp await_delivery_or_rejection(event_id) do
    receive do
      {:event_core, %Envelope{event_id: ^event_id}} ->
        :ok

      {:event_core, %Envelope{type: "delivery.rejected", causation_id: ^event_id} = env} ->
        {:rejected, env}
    after
      @delivery_timeout -> raise "event #{event_id} was committed but never delivered"
    end
  end

  defp await_delivery(event_id) do
    receive do
      {:event_core, %Envelope{event_id: ^event_id}} -> :ok
    after
      @delivery_timeout -> raise "event #{event_id} was committed but never delivered"
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

  defp maybe_put_notes(checkpoint, nil), do: checkpoint
  defp maybe_put_notes(checkpoint, notes), do: Map.put(checkpoint, "notes", notes)

  defp pending_from_messages(messages, child_ids) do
    tool_call_ids =
      messages
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
          Enum.map(calls, fn call -> call["id"] || call[:id] end)

        _ ->
          nil
      end)

    child_ids
    |> Enum.zip(tool_call_ids)
    |> Map.new()
  end

  defp checkpoint_awaiting(checkpoint) do
    fetch_key(checkpoint, "awaiting") || []
  end

  defp checkpoint_messages(checkpoint) do
    case fetch_key(checkpoint, "messages") do
      messages when is_list(messages) -> messages
      _ -> nil
    end
  end

  defp tool_state_from(checkpoint) when is_map(checkpoint) do
    base =
      case fetch_key(checkpoint, "tool_state") do
        nil ->
          checkpoint
          |> Map.drop(["messages", "awaiting", "pending", "tool_state", "notes"])
          |> Map.drop([:messages, :awaiting, :pending, :tool_state, :notes])

        tool_state ->
          tool_state
      end

    atomize_tool_state(base)
  end

  defp tool_state_from(_), do: %{}

  defp fetch_key(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_key(_, _), do: nil

  defp atomize_tool_state(map) when is_map(map) do
    Map.new(map, fn {tool, state} when is_map(state) ->
      {to_string(tool),
       Map.new(state, fn
         {k, v} when is_binary(k) -> {String.to_atom(k), v}
         {k, v} when is_atom(k) -> {k, v}
       end)}
    end)
  end

  defp bands_from_agent(agent) do
    %{
      "granted" => agent.tools,
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp tools_pin(state) do
    state[:tools] || bands_from_agent(state.agent)
  end

  defp maybe_put_policy_hash(payload, nil), do: payload
  defp maybe_put_policy_hash(payload, hash), do: Map.put(payload, :policy_hash, hash)
end
