Code.require_file("../../scripts/support/workflow_observer.exs", __DIR__)

defmodule Omunculus.WorkflowObserverTest do
  use ExUnit.Case, async: true
  alias Omunculus.WorkflowObserver

  test "child completion, failed attempts and parental breaks are not terminal outcomes" do
    task = Task.async(fn -> WorkflowObserver.await("root") end)

    for event <- [
          %{type: "task.completed", work_item_id: "child"},
          %{type: "run.failed", work_item_id: "root"},
          %{type: "task.break", payload: %{"reviewer" => "root"}},
          %{type: "task.commented", payload: %{"kind" => "request"}}
        ] do
      send(task.pid, {:event_core, event})
    end

    assert Task.yield(task, 20) == nil
    terminal = %{type: "task.completed", work_item_id: "root"}
    send(task.pid, {:event_core, terminal})
    assert Task.await(task) == {:completed, terminal}
  end

  test "human assessment on a child ends observation as awaiting human" do
    terminal = %{
      type: "task.commented",
      work_item_id: "child",
      payload: %{"kind" => "request", "assessment" => true}
    }

    send(self(), {:event_core, terminal})
    assert WorkflowObserver.await("root") == {:awaiting_human, terminal}
  end
end
