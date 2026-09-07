defmodule Omunculus.SessionExecutorTest do
  use ExUnit.Case, async: false
  alias Omunculus.{EventCore, Harness, Runtime, SessionExecutor}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents
  alias Omunculus.Chat.Fake

  setup do
    tmp = Harness.tmp_fixture("simple.toml")
    db = Path.join(tmp.dir, "session.sqlite3")

    on_exit(fn ->
      case :global.whereis_name({SessionExecutor, db}) do
        pid when is_pid(pid) -> SessionExecutor.stop(pid)
        _ -> :ok
      end

      File.rm_rf!(tmp.dir)
    end)

    %{tmp: tmp, db: db}
  end

  test "separate core writer wakes a live runtime exactly once", %{tmp: tmp, db: db} do
    {:ok, owner} =
      SessionExecutor.ensure_started(
        db: db,
        cwd: tmp.dir,
        config_file: tmp.path,
        provider: "fake"
      )

    assert {:ok, ^owner} = SessionExecutor.ensure_started(db: db, cwd: tmp.dir)
    {:ok, writer} = EventCore.start_link(path: db, poll_ms: 10)
    on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    execution = %{cwd: tmp.dir, config_file: tmp.path, profile: "count", provider: "fake"}

    assert {:ok, %{result: "3", requested: request}} =
             Runtime.request(writer, "conte até 3", execution: execution, timeout: 3_000)

    core = SessionExecutor.core(owner)
    EventCore.poll(core)
    EventCore.poll(core)

    assert length(
             EventCore.stream(core, 0, work_item_id: request.work_item_id, type: "run.started")
           ) == 1

    assert length(
             EventCore.stream(core, 0, work_item_id: request.work_item_id, type: "task.completed")
           ) == 1
  end

  test "external permission response resumes waiting work without restarting owner", %{
    tmp: tmp,
    db: db
  } do
    File.write!(
      tmp.path,
      "[profiles.coding]\nmode = \"allow\"\nhuman = [\"write\"]\n[policy.depth.0]\nmode = \"allow\"\nhuman = [\"write\"]\n"
    )

    script = fn _, _, _, _, reason ->
      if reason == "continuation",
        do: [Fake.text("granted and resumed")],
        else: [Fake.tool_call("request_permission", %{"tool" => "write", "reason" => "needed"})]
    end

    {:ok, owner} =
      SessionExecutor.ensure_started(
        db: db,
        cwd: tmp.dir,
        config_file: tmp.path,
        agents: Agents.resolver(script: script)
      )

    core = SessionExecutor.core(owner)
    task = Task.async(fn -> Runtime.request(core, "write", timeout: 5_000) end)
    req = Harness.await_log(core, &(&1.type == "permission.requested"))
    Harness.await_log(core, &(&1.type == "run.completed" and &1.payload["outcome"] == "waiting"))
    {:ok, writer} = EventCore.start_link(path: db)

    EventCore.append!(
      writer,
      Envelope.command("permission.granted",
        work_item_id: req.work_item_id,
        correlation_id: req.correlation_id,
        causation_id: req.event_id,
        payload: %{
          request_id: req.payload["request_id"],
          kind: "temporary",
          granter: "human:test"
        }
      )
    )

    GenServer.stop(writer)
    assert {:ok, %{result: "granted and resumed"}} = Task.await(task, 5_000)
    assert Process.alive?(owner)
    Projector.sync_core(core)
  end

  test "detached CLI request completes in inbox after caller returns", %{tmp: tmp, db: db} do
    assert Omunculus.CLI.dispatch(
             [
               "send",
               "conte até 3",
               "--provider",
               "fake",
               "--profile",
               "count",
               "--config",
               tmp.path,
               "--session",
               db,
               "--detach"
             ],
             %{}
           ) == 0

    owner = :global.whereis_name({SessionExecutor, db})
    core = SessionExecutor.core(owner)
    done = Harness.await_log(core, &(&1.type == "task.completed" and &1.payload["depth"] == 0))
    assert done.payload["result"] == "3"
    Projector.sync_core(core)

    assert [["3"]] =
             EventCore.query(core, "SELECT body FROM COMMENTS WHERE work_item_id = ?", [
               done.work_item_id
             ])
  end

  test "restart executes a queued command once and rechecks workspace access", %{tmp: tmp, db: db} do
    {:ok, writer} = EventCore.start_link(path: db)

    EventCore.append!(
      writer,
      Envelope.command("workspace.attached", payload: %{workspace_id: "app"})
    )

    rejected =
      EventCore.append!(
        writer,
        Envelope.command("task.requested",
          work_item_id: "blocked",
          payload: %{instruction: "conte até 2", workspace: "outside"}
        )
      )

    accepted =
      EventCore.append!(
        writer,
        Envelope.command("task.requested",
          work_item_id: "queued",
          payload: %{
            instruction: "conte até 2",
            workspace: "app",
            execution: %{profile: "count", provider: "fake", cwd: tmp.dir, config_file: tmp.path}
          }
        )
      )

    Projector.sync_core(writer)

    assert [[1]] =
             EventCore.query(
               writer,
               "SELECT count(*) FROM WORK_ITEMS WHERE work_item_id = 'blocked'"
             )

    GenServer.stop(writer)

    {:ok, owner} =
      SessionExecutor.ensure_started(
        db: db,
        cwd: tmp.dir,
        config_file: tmp.path,
        provider: "fake"
      )

    core = SessionExecutor.core(owner)
    Harness.await_log(core, &(&1.type == "task.completed" and &1.work_item_id == "queued"))

    Harness.await_log(
      core,
      &(&1.type == "delivery.rejected" and &1.causation_id == rejected.event_id)
    )

    EventCore.redeliver(core, accepted.event_id)
    Projector.sync_core(core)

    assert [[0]] =
             EventCore.query(
               core,
               "SELECT count(*) FROM WORK_ITEMS WHERE work_item_id = 'blocked'"
             )

    assert length(EventCore.stream(core, 0, work_item_id: "queued", type: "run.started")) == 1
    snapshot = Projector.snapshot(core)
    Projector.rebuild(:sys.get_state(owner).projector)
    assert snapshot == Projector.snapshot(core)
  end
end
