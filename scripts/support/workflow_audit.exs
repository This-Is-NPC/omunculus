defmodule Omunculus.WorkflowAudit do
  @moduledoc "Measure delivered handoffs separately from rejected delivery attempts."

  def handoffs(events) do
    rejected =
      events
      |> Enum.filter(&(&1.type == "delivery.rejected"))
      |> MapSet.new(& &1.payload["rejected_event_id"])

    starts = Enum.filter(events, &(&1.type == "run.started"))

    {blocked, delivered} =
      events
      |> Enum.filter(&(&1.type == "task.delegated"))
      |> Enum.split_with(&MapSet.member?(rejected, &1.event_id))

    %{
      accepted_delegations: length(delivered),
      rejected_delegations: length(blocked),
      handoffs_valid:
        Enum.all?(delivered, fn event ->
          match?({:ok, _}, Omunculus.WorkItem.handoff(event.payload)) and
            Enum.any?(
              starts,
              &(&1.work_item_id == event.payload["child_work_item_id"] and
                  &1.payload["work_item"] == event.payload["work_item"] and
                  &1.payload["comment"] == event.payload["comment"])
            )
        end),
      rejected_handoffs_blocked:
        Enum.all?(blocked, fn event ->
          not Enum.any?(starts, &(&1.work_item_id == event.payload["child_work_item_id"]))
        end)
    }
  end
end
