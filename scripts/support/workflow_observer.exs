defmodule Omunculus.WorkflowObserver do
  @moduledoc "Observes protocol outcomes without imposing a task deadline."

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
