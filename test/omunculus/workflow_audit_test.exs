Code.require_file("../../scripts/support/workflow_audit.exs", __DIR__)

defmodule Omunculus.WorkflowAuditTest do
  use ExUnit.Case, async: true
  alias Omunculus.Event.Envelope
  alias Omunculus.WorkflowAudit

  test "a rejected handoff needs no child, but must never start one" do
    task = %{"instruction" => "work"}

    rejected =
      Envelope.event("task.delegated",
        payload: %{
          work_item: task,
          comment: "context",
          child_work_item_id: "blocked"
        }
      )

    rejection =
      Envelope.event("delivery.rejected", payload: %{rejected_event_id: rejected.event_id})

    accepted =
      Envelope.event("task.delegated",
        payload: %{
          work_item: task,
          comment: "context",
          child_work_item_id: "accepted"
        }
      )

    child =
      Envelope.event("run.started",
        work_item_id: "accepted",
        payload: %{work_item: task, comment: "context"}
      )

    events = [rejected, rejection, accepted, child]

    assert WorkflowAudit.handoffs(events) == %{
             accepted_delegations: 1,
             rejected_delegations: 1,
             handoffs_valid: true,
             rejected_handoffs_blocked: true
           }

    refute WorkflowAudit.handoffs([rejected, rejection, accepted]).handoffs_valid

    refute WorkflowAudit.handoffs(events ++ [%{child | work_item_id: "blocked"}]).rejected_handoffs_blocked

    refute WorkflowAudit.handoffs([
             accepted,
             %{child | payload: Map.put(child.payload, "comment", "wrong context")}
           ]).handoffs_valid
  end
end
