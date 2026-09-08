defmodule Omunculus.Runtime.Recovery do
  @moduledoc "Durable recovery reservations shared by a Work Item stage and its verification work."
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Store
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Workflow

  def for_run(state, stage) do
    case state[:assessment] do
      %{"target" => target} -> reference(state.core, target)
      _ -> reference(state.core, state.work_item_id, state.agent, stage)
    end
  end

  def reference(core, id, agent \\ %{}, stage \\ nil) do
    delegated =
      Enum.find(
        EventCore.stream(core, 0, type: "task.delegated"),
        &(&1.payload["child_work_item_id"] == id)
      )

    inherited = delegated && delegated.payload["recovery"]
    starts = EventCore.stream(core, 0, work_item_id: id, type: "run.started")
    first = List.first(starts)
    flow = agent[:flow] || (first && first.payload["flow"]) || %{}
    stage = if flow["steps"] in [nil, []], do: "work", else: stage || Workflow.stage(core, id)

    pinned =
      Enum.find_value(starts, fn start ->
        ref = start.payload["recovery"]
        if ref && ref["work_item_id"] == id && ref["stage"] == stage, do: ref
      end)

    inherited || pinned ||
      %{
        "work_item_id" => id,
        "stage" => stage,
        "max_retries" => agent[:max_retries] || (first && first.payload["max_retries"]) || 2
      }
  end

  def reserve(core, ref, cause, reason) do
    EventCore.append(
      core,
      Envelope.event("task.recovery_used",
        work_item_id: ref["work_item_id"],
        run_id: cause.run_id,
        correlation_id: cause.correlation_id,
        session_id: cause.session_id,
        project_id: cause.project_id,
        workspace_id: cause.workspace_id,
        causation_id: cause.event_id,
        idempotency_key: "recovery:#{cause.event_id}:#{ref["work_item_id"]}:#{reason}",
        payload: %{"recovery" => ref, "reason" => reason}
      )
    )
  end

  def used(core, ref) do
    [[used]] = EventCore.query(core, count_sql(), [ref["work_item_id"], ref["stage"]])
    used
  end

  # Called inside EventCore's existing write transaction, after deduplication.
  def guard(conn, %{type: "task.recovery_used", payload: %{"recovery" => ref}}) do
    [[used]] = Store.query(conn, count_sql(), [ref["work_item_id"], ref["stage"]])
    if used < ref["max_retries"], do: :ok, else: {:error, :max_retries_exhausted}
  end

  def guard(_conn, _env), do: :ok

  defp count_sql do
    "SELECT count(*) FROM EVENTS WHERE type = 'task.recovery_used' AND work_item_id = ? AND json_extract(payload, '$.recovery.stage') = ?"
  end
end
