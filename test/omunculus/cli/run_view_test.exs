defmodule Omunculus.CLI.RunViewTest do
  use ExUnit.Case, async: true
  alias Omunculus.CLI.UI.RunView
  alias Omunculus.Event.Envelope

  defp env(id, type, payload, opts \\ []) do
    Envelope.event(
      type,
      Keyword.merge(
        [
          event_id: id,
          run_id: id,
          session_id: "session-full",
          work_item_id: "work-full",
          occurred_at: "2026-09-08T14:32:10-03:00",
          payload: payload
        ],
        opts
      )
    )
  end

  test "header resolves exact parent and retry comment; summary uses recorded interval" do
    parent = env("parent-run", "run.started", %{agent_id: "concierge", model: "parent-model"})

    trigger =
      env("retry-event", "task.run_requested", %{
        comment: "Correct the result using evidence",
        instruction: "OLD OBJECTIVE"
      })

    start =
      env(
        "child-run",
        "run.started",
        %{
          agent_id: "worker",
          agent_kind: "worker",
          model: "child-model",
          parent_run_id: "parent-run",
          originating_run_id: "origin-run",
          stage: "review",
          reason: "retry",
          attempt: 2,
          available_tools: ["read", "request_permission"]
        },
        causation_id: "retry-event"
      )

    r = RunView.new(start)

    header =
      RunView.header(r, %{"parent-run" => parent}, %{"retry-event" => trigger}) |> Enum.join("\n")

    for text <- [
          "session-full",
          "child-run",
          "parent-run",
          "parent-model",
          "child-model",
          "Correct the result",
          "request_permission",
          "retry-event",
          "08/09/2026 14:32:10 -03:00"
        ],
        do: assert(header =~ text)

    refute header =~ "OLD OBJECTIVE"

    finish =
      env("end", "run.completed", %{outcome: "reported"},
        occurred_at: "2026-09-08T15:37:42-03:00"
      )

    r = RunView.update(r, finish)
    assert RunView.elapsed(r) == "1h 5m 32s"
    output = Enum.join(RunView.summary(r), "\n")
    assert output =~ "08/09/2026 15:37:42 -03:00"
    assert output =~ "1h 5m 32s"
    assert output =~ "not recorded"
  end

  test "missing child comment never inherits the original human objective" do
    root = env("root-request", "task.requested", %{instruction: "ROOT OBJECTIVE"})

    delegated =
      env("delegated", "task.delegated", %{instruction: "CHILD OBJECTIVE"},
        causation_id: "root-request"
      )

    start = env("child", "run.started", %{}, causation_id: "delegated")

    header =
      RunView.header(RunView.new(start), %{}, %{"root-request" => root, "delegated" => delegated})
      |> Enum.join("\n")

    refute header =~ "ROOT OBJECTIVE"
    refute header =~ "CHILD OBJECTIVE"
    assert header =~ "Input comment"
    assert RunView.elapsed(RunView.new(start)) == "not recorded"
  end

  test "round totals ignore checkpoint duplicates and indicate partial token usage" do
    r = RunView.new(env("r", "run.started", %{}))

    r =
      RunView.update(
        r,
        env("m1", "model.call.completed", %{round: 1, usage: %{total_tokens: 12}, duration_ms: 30})
      )

    r = RunView.update(r, env("m2", "model.call.failed", %{round: 2, duration_ms: 20}))
    r = RunView.update(r, env("t", "tool.call.completed", %{round: 1, duration_ms: 1}))

    r =
      RunView.update(
        r,
        env("end", "run.completed", %{checkpoint: %{usage: %{total_tokens: 9999}}})
      )

    output = Enum.join(RunView.summary(r), "\n")
    assert output =~ "12 (partial)"
    refute output =~ "9999"
    assert output =~ "51ms"
  end
end
