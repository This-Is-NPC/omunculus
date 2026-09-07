defmodule Omunculus.CLI.InboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Omunculus.CLI.Parser
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    db = Path.join(System.tmp_dir!(), "omunculus-inbox-test-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(db) end)
    %{db: db}
  end

  test "inbox lists an open permission.requested", %{db: db} do
    seed_open_request(db, "req-edit", "patch file")

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(["inbox", "--db", db], %{}) == 0
      end)

    assert out =~ "request_id=req-edit"
    assert out =~ "tool=edit"
    assert out =~ "task=\"patch file\""
  end

  test "inbox reply --grant appends permission.granted", %{db: db} do
    seed_open_request(db, "req-edit", "patch file")

    assert Omunculus.CLI.dispatch(["inbox", "reply", "req-edit", "--grant", "--db", db], %{}) ==
             0

    {:ok, core} = EventCore.start_link(path: db)

    [granted] = EventCore.stream(core, 0, type: "permission.granted")
    assert granted.payload["request_id"] == "req-edit"
    assert granted.payload["kind"] == "temporary"
    assert granted.payload["granter"] == "human:cli"
    GenServer.stop(core)
  end

  test "inbox reply --deny appends permission.denied", %{db: db} do
    seed_open_request(db, "req-delete", "remove file")

    assert Omunculus.CLI.dispatch(
             ["inbox", "reply", "req-delete", "--deny", "--reason", "nope", "--db", db],
             %{}
           ) == 0

    {:ok, core} = EventCore.start_link(path: db)
    [denied] = EventCore.stream(core, 0, type: "permission.denied")
    assert denied.payload["request_id"] == "req-delete"
    assert denied.payload["reason"] == "nope"
    GenServer.stop(core)
  end

  test "inbox read sets COMMENTS.read_at", %{db: db} do
    comment_id = seed_unread_result(db)

    assert Omunculus.CLI.dispatch(["inbox", "read", comment_id, "--db", db], %{}) == 0

    {:ok, core} = EventCore.start_link(path: db)
    {:ok, projector} = Projector.start_link(core: core)
    :ok = Projector.sync(projector)

    assert [[_read_at]] =
             EventCore.query(
               core,
               "SELECT read_at FROM COMMENTS WHERE comment_id = ?",
               [comment_id]
             )

    refute is_nil(_read_at)
    GenServer.stop(projector)
    GenServer.stop(core)
  end

  test "emit permission.granted --request-id fills payload and is injectable", %{db: db} do
    seed_open_request(db, "req-edit", "patch file")

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(
                 ["emit", "permission.granted", "--db", db, "--request-id", "req-edit"],
                 %{}
               ) == 0
      end)

    decoded = Jason.decode!(out)
    assert decoded["payload"]["request_id"] == "req-edit"
    assert decoded["payload"]["kind"] == "temporary"
    assert decoded["payload"]["granter"] == "human:cli"
    assert decoded["work_item_id"] == "wi-1"
    assert decoded["session_id"] == "sess-1"
    assert is_binary(decoded["correlation_id"])
  end

  test "emit --session selects the session sqlite file via dispatch env" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    db = Path.join(System.tmp_dir!(), "omunculus-emit-session-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(db) end)

    seed_open_request(db, "req-edit", "patch file")

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(
                 ["emit", "permission.granted", "--request-id", "req-edit"],
                 %{"OMUNCULUS_SESSION" => db}
               ) == 0
      end)

    decoded = Jason.decode!(out)
    assert decoded["payload"]["request_id"] == "req-edit"
  end

  test "inbox reply --grant --permanent edits tmp TOML and appends policy.changed", %{db: db} do
    dir =
      Path.join(System.tmp_dir!(), "omunculus-inbox-perm-#{System.unique_integer([:positive])}")

    :ok = File.mkdir_p!(dir)
    config = Path.join(dir, "omunculus.toml")

    File.write!(
      config,
      """
      [workspaces.app]
      roots = ["."]
      mode = "allow"
      human = ["edit"]

      [profiles.coding]
      mode = "allow"
      """
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    seed_open_request(db, "req-edit", "patch file", workspace: "app")

    assert Omunculus.CLI.dispatch(
             [
               "inbox",
               "reply",
               "req-edit",
               "--grant",
               "--permanent",
               "--db",
               db,
               "--config",
               config
             ],
             %{}
           ) == 0

    body = File.read!(config)
    assert body =~ "granted = [\"edit\"]"
    refute body =~ "human = [\"edit\"]"

    {:ok, core} = EventCore.start_link(path: db)
    assert Enum.any?(EventCore.stream(core, 0, type: "policy.changed"))
    [granted] = EventCore.stream(core, 0, type: "permission.granted")
    assert granted.payload["kind"] == "permanent"
    GenServer.stop(core)
  end

  test "parser accepts inbox reply grant and emit request-id flags" do
    assert {:ok,
            %{command: :inbox, args: %{action: "reply", id: "req_abc"}, flags: %{"grant" => true}}} =
             Parser.parse(["inbox", "reply", "req_abc", "--grant"], %{})

    assert {:ok, %{command: :emit, flags: %{"request_id" => "req_abc"}}} =
             Parser.parse(["emit", "permission.granted", "--request-id", "req_abc"], %{})
  end

  defp seed_open_request(db, request_id, instruction, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, "app")
    {:ok, core} = EventCore.start_link(path: db)
    {:ok, projector} = Projector.start_link(core: core)

    cmd =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          session_id: "sess-1",
          work_item_id: "wi-1",
          workspace_id: workspace,
          payload: %{instruction: instruction, workspace: workspace}
        )
      )

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          session_id: "sess-1",
          work_item_id: "wi-1",
          run_id: "run-1",
          correlation_id: cmd.correlation_id,
          causation_id: cmd.event_id,
          payload: %{
            depth: 0,
            attempt: 1,
            agent_id: "worker",
            agent_kind: "worker",
            reason: "initial",
            tools: %{"granted" => [], "negotiable" => [], "human" => ["edit"], "forbidden" => []}
          }
        )
      )

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        session_id: "sess-1",
        work_item_id: "wi-1",
        workspace_id: workspace,
        correlation_id: cmd.correlation_id,
        causation_id: started.event_id,
        run_id: "run-1",
        payload: %{
          request_id: request_id,
          tool: "edit",
          arbiter: "human",
          workspace: workspace,
          reason: "need edit"
        }
      )
    )

    EventCore.append!(
      core,
      Envelope.event("run.completed",
        session_id: "sess-1",
        work_item_id: "wi-1",
        run_id: "run-1",
        correlation_id: cmd.correlation_id,
        causation_id: started.event_id,
        payload: %{outcome: "waiting", awaiting: [request_id], checkpoint: %{}}
      )
    )

    :ok = Projector.sync(projector)
    GenServer.stop(projector)
    GenServer.stop(core)
  end

  defp seed_unread_result(db) do
    {:ok, core} = EventCore.start_link(path: db)
    {:ok, projector} = Projector.start_link(core: core)

    EventCore.append!(
      core,
      Envelope.command("task.requested",
        session_id: "sess-1",
        work_item_id: "wi-root",
        payload: %{instruction: "root task"}
      )
    )

    completed =
      EventCore.append!(
        core,
        Envelope.event("task.completed",
          session_id: "sess-1",
          work_item_id: "wi-root",
          causation_id: "evt-root",
          correlation_id: "corr-root",
          payload: %{result: "done", depth: 0}
        )
      )

    :ok = Projector.sync(projector)
    GenServer.stop(projector)
    GenServer.stop(core)
    completed.event_id
  end
end
