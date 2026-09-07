defmodule Omunculus.EventCoreTest do
  use ExUnit.Case, async: true

  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector

  @empty_tools %{
    "granted" => [],
    "negotiable" => [],
    "human" => [],
    "forbidden" => []
  }

  setup do
    {:ok, core} = EventCore.start_link(path: ":memory:")
    {:ok, projector} = Projector.start_link(core: core)
    %{core: core, projector: projector}
  end

  test "append assigns a monotonic sequence and persists before notifying", %{core: core} do
    :ok = EventCore.subscribe(core)

    cmd = Envelope.command("task.requested", payload: %{instruction: "x"}, work_item_id: "wi-1")
    {:ok, stored} = EventCore.append(core, cmd)
    assert stored.sequence == 1
    assert stored.payload == %{"instruction" => "x"}

    assert_receive {:event_core, %Envelope{event_id: id, sequence: 1}}
    assert id == cmd.event_id
    assert [%Envelope{sequence: 1}] = EventCore.stream(core, 0)

    evt =
      Envelope.event("run.completed",
        correlation_id: cmd.correlation_id,
        causation_id: cmd.event_id,
        payload: %{outcome: "completed"}
      )

    {:ok, %{sequence: 2}} = EventCore.append(core, evt)
  end

  test "events require a causation id", %{core: core} do
    assert {:error, :event_requires_causation} =
             EventCore.append(core, Envelope.event("run.completed", correlation_id: "c"))
  end

  test "redelivery of the same event_id is idempotent, different content conflicts", %{core: core} do
    :ok = EventCore.subscribe(core)
    cmd = Envelope.command("task.requested", payload: %{instruction: "a"})
    {:ok, first} = EventCore.append(core, cmd)
    {:ok, again} = EventCore.append(core, cmd)
    assert again == first
    assert_receive {:event_core, _}
    refute_receive {:event_core, _}, 50

    assert {:error, {:event_id_conflict, _}} =
             EventCore.append(core, %{cmd | payload: %{"instruction" => "b"}})

    assert length(EventCore.stream(core, 0)) == 1
  end

  test "idempotency key returns the first result or an explicit conflict", %{core: core} do
    a = Envelope.command("task.requested", payload: %{instruction: "a"}, idempotency_key: "k1")
    b = Envelope.command("task.requested", payload: %{instruction: "a"}, idempotency_key: "k1")
    c = Envelope.command("task.requested", payload: %{instruction: "z"}, idempotency_key: "k1")

    {:ok, stored_a} = EventCore.append(core, a)
    {:ok, stored_b} = EventCore.append(core, b)
    assert stored_b.event_id == stored_a.event_id
    assert {:error, {:idempotency_conflict, "k1"}} = EventCore.append(core, c)
    assert length(EventCore.stream(core, 0)) == 1
  end

  test "stream filters by correlation and reads in sequence order", %{core: core} do
    c1 = EventCore.append!(core, Envelope.command("task.resumed", correlation_id: "c1"))
    _c2 = EventCore.append!(core, Envelope.command("task.resumed", correlation_id: "c2"))

    e1 =
      EventCore.append!(
        core,
        Envelope.event("run.completed",
          correlation_id: "c1",
          causation_id: c1.event_id,
          payload: %{outcome: "completed"}
        )
      )

    assert [^c1, ^e1] = EventCore.stream(core, 0, correlation_id: "c1")
    assert [^e1] = EventCore.stream(core, 1, correlation_id: "c1")
  end

  test "projector reduces work items and runs, and rebuild is deterministic", %{
    core: core,
    projector: projector
  } do
    cmd =
      EventCore.append!(
        core,
        Envelope.command("task.requested", payload: %{instruction: "count"}, work_item_id: "wi-1")
      )

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          correlation_id: cmd.correlation_id,
          causation_id: cmd.event_id,
          work_item_id: "wi-1",
          run_id: "run-1",
          payload: %{
            attempt: 1,
            depth: 0,
            agent_id: "a",
            agent_kind: "worker",
            reason: "initial",
            tools: @empty_tools
          }
        )
      )

    done =
      EventCore.append!(
        core,
        Envelope.event("task.completed",
          correlation_id: cmd.correlation_id,
          causation_id: started.event_id,
          work_item_id: "wi-1",
          run_id: "run-1",
          payload: %{result: "10", depth: 0}
        )
      )

    EventCore.append!(
      core,
      Envelope.event("run.completed",
        correlation_id: cmd.correlation_id,
        causation_id: done.event_id,
        work_item_id: "wi-1",
        run_id: "run-1",
        payload: %{outcome: "completed"}
      )
    )

    :ok = Projector.sync(projector)
    assert Projector.cursor(projector) == 4

    assert [["wi-1", "completed", "10"]] =
             EventCore.query(core, "SELECT work_item_id, status, result FROM WORK_ITEMS")

    assert [["run-1", "completed", "completed", 1, 0]] =
             EventCore.query(
               core,
               "SELECT run_id, status, outcome, attempt, depth FROM ARCHIVE_RUNS"
             )

    before = Projector.snapshot(core)
    :ok = Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
    assert Projector.cursor(projector) == 4
  end

  test "run.completed with outcome waiting projects awaiting and archive status", %{
    core: core,
    projector: projector
  } do
    cmd =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          payload: %{instruction: "delegate"},
          work_item_id: "wi-parent"
        )
      )

    EventCore.append!(
      core,
      Envelope.event("run.started",
        correlation_id: cmd.correlation_id,
        causation_id: cmd.event_id,
        work_item_id: "wi-parent",
        run_id: "run-1",
        payload: %{
          attempt: 1,
          depth: 0,
          agent_id: "a",
          agent_kind: "concierge",
          reason: "initial",
          tools: @empty_tools
        }
      )
    )

    EventCore.append!(
      core,
      Envelope.event("run.completed",
        correlation_id: cmd.correlation_id,
        causation_id: cmd.event_id,
        work_item_id: "wi-parent",
        run_id: "run-1",
        payload: %{
          outcome: "waiting",
          awaiting: ["wi-child"],
          checkpoint: %{"messages" => []}
        }
      )
    )

    :ok = Projector.sync(projector)

    assert [["waiting", "waiting", "initial"]] =
             EventCore.query(
               core,
               "SELECT status, outcome, reason FROM ARCHIVE_RUNS WHERE run_id = 'run-1'"
             )

    assert [["waiting", ~s(["wi-child"])]] =
             EventCore.query(
               core,
               "SELECT state, awaiting FROM WORK_ITEMS WHERE work_item_id = 'wi-parent'"
             )
  end

  test "workspace.attached projects SESSION_WORKSPACES", %{core: core, projector: projector} do
    EventCore.append!(
      core,
      Envelope.command("workspace.attached",
        session_id: "sess-1",
        payload: %{
          workspace_id: "ws-app",
          roots: ["/app"],
          teams: ["app"]
        }
      )
    )

    :ok = Projector.sync(projector)

    assert [["ws-app", ~s(["/app"]), ~s(["app"]), 1]] =
             EventCore.query(
               core,
               "SELECT workspace_id, roots, teams, attached FROM SESSION_WORKSPACES"
             )
  end

  test "task.commented projects COMMENTS", %{core: core, projector: projector} do
    EventCore.append!(
      core,
      Envelope.command("task.commented",
        session_id: "sess-1",
        work_item_id: "wi-1",
        payload: %{body: "please review", kind: "request"}
      )
    )

    :ok = Projector.sync(projector)

    assert [["wi-1", "request", "please review", "sess-1"]] =
             EventCore.query(
               core,
               "SELECT work_item_id, kind, body, session_id FROM COMMENTS"
             )
  end

  test "permission.requested projects COMMENTS as request", %{core: core, projector: projector} do
    cmd =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          session_id: "sess-1",
          work_item_id: "wi-1",
          payload: %{instruction: "patch"}
        )
      )

    requested =
      EventCore.append!(
        core,
        Envelope.event("permission.requested",
          correlation_id: cmd.correlation_id,
          causation_id: cmd.event_id,
          session_id: "sess-1",
          work_item_id: "wi-1",
          run_id: "run-1",
          payload: %{request_id: "req-edit", tool: "edit", reason: "need to patch"}
        )
      )

    :ok = Projector.sync(projector)

    event_id = requested.event_id

    assert [["wi-1", "request", "need to patch", ^event_id]] =
             EventCore.query(
               core,
               "SELECT work_item_id, kind, body, event_id FROM COMMENTS"
             )
  end

  test "permission.granted and permission.denied project COMMENTS responses", %{
    core: core,
    projector: projector
  } do
    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        session_id: "sess-1",
        work_item_id: "wi-1",
        payload: %{request_id: "req-edit", kind: "temporary", granter: "human:cli"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.denied",
        session_id: "sess-1",
        work_item_id: "wi-2",
        payload: %{request_id: "req-delete", reason: "forbidden"}
      )
    )

    :ok = Projector.sync(projector)

    assert [
             ["wi-1", "response", "temporary by human:cli"],
             ["wi-2", "response", "forbidden"]
           ] =
             EventCore.query(
               core,
               "SELECT work_item_id, kind, body FROM COMMENTS ORDER BY work_item_id"
             )
  end

  test "inbox.read sets COMMENTS.read_at by comment or event id", %{
    core: core,
    projector: projector
  } do
    comment =
      EventCore.append!(
        core,
        Envelope.command("task.commented",
          session_id: "sess-1",
          work_item_id: "wi-1",
          payload: %{body: "done", kind: "result"}
        )
      )

    EventCore.append!(
      core,
      Envelope.command("inbox.read",
        session_id: "sess-1",
        payload: %{id: comment.event_id}
      )
    )

    :ok = Projector.sync(projector)

    assert [[read_at]] =
             EventCore.query(core, "SELECT read_at FROM COMMENTS WHERE comment_id = ?", [
               comment.event_id
             ])

    refute is_nil(read_at)
  end
end
