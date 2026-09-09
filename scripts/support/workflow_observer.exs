defmodule Omunculus.WorkflowObserver do
  @moduledoc "Observes protocol outcomes without imposing a task deadline."

  def request(core, instruction, opts) do
    alias Omunculus.{EventCore, Event.Envelope}
    :ok = EventCore.subscribe(core, session_id: opts[:session_id])

    try do
      requested =
        EventCore.append!(
          core,
          Envelope.command("task.requested",
            session_id: opts[:session_id],
            work_item_id: Envelope.generate_id("wi"),
            payload: %{
              instruction: instruction,
              depth: 0,
              workspace: opts[:workspace],
              execution: opts[:execution] || %{}
            }
          )
        )

      case await(requested.work_item_id) do
        {:completed, event} ->
          {:ok, %{result: event.payload["result"], requested: requested, completed: event}}

        {:awaiting_human, event} ->
          {:error, {:awaiting_human, event.payload}}
      end
    after
      EventCore.unsubscribe(core)
    end
  end

  def await(root_id) do
    receive do
      {:event_core, %{type: "task.completed", work_item_id: ^root_id} = event} ->
        {:completed, event}

      {:event_core,
       %{type: "task.commented", payload: %{"kind" => "request", "assessment" => true}} =
           event} ->
        {:awaiting_human, event}

      {:event_core, %{type: "interception.requested", payload: %{"actor" => "human"}} = event} ->
        {:awaiting_human, event}

      {:event_core, _event} ->
        await(root_id)
    end
  end
end
