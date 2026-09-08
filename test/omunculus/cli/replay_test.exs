defmodule Omunculus.CLI.ReplayTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Omunculus.{CLI, EventCore, Runtime}
  alias Omunculus.CLI.{Replay, Reporter}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.{Projector, Store}
  alias Omunculus.Runtime.Agents
  alias Omunculus.Chat.Fake

  setup do
    dir = Path.join(System.tmp_dir!(), "replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, db: Path.join(dir, "session.sqlite3")}
  end

  test "live committed stream and passive replay are identical without writes", %{db: db} do
    core = start_supervised!({EventCore, path: db})
    projector = start_supervised!({Projector, core: core})
    {:ok, io} = StringIO.open("")
    {:ok, reporter} = Reporter.start_link(core: core, io: io, path: db)
    runtime = start_supervised!({Runtime, core: core, max_depth: 1, agents: Agents.resolver()})
    assert {:ok, %{result: "3"}} = Runtime.request(core, "conte até 3")
    GenServer.stop(runtime)
    Projector.sync(projector)
    Reporter.finish(reporter)
    before = Projector.snapshot(core)
    history = EventCore.stream(core, 0)

    output =
      capture_io(fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 0 end)

    assert tl(String.split(output, "\n")) ==
             tl(String.split(elem(StringIO.contents(io), 1), "\n"))

    assert Projector.snapshot(core) == before
    assert EventCore.stream(core, 0) == history
    GenServer.stop(projector)
    GenServer.stop(core)
    bytes = File.read!(db)
    capture_io(fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 0 end)
    assert File.read!(db) == bytes
  end

  test "fixed read snapshot includes WAL and excludes later appends", %{db: db} do
    core = start_supervised!({EventCore, path: db})
    EventCore.transaction(core, fn conn -> Store.query(conn, "PRAGMA journal_mode") end)

    first =
      EventCore.append!(core, Envelope.command("session.created", payload: %{session_id: "test"}))

    owner = self()

    assert :ok =
             Replay.read(db, fn event ->
               send(owner, {:read, event.event_id})

               EventCore.append!(
                 core,
                 Envelope.command("session.created", payload: %{session_id: "later"})
               )
             end)

    assert_received {:read, id}
    assert id == first.event_id
    refute_received {:read, _}
    assert length(EventCore.stream(core, 0)) == 2
  end

  test "absent and invalid files fail without creation or migration", %{db: db} do
    assert capture_io(:stderr, fn ->
             assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 1
           end) =~ "replay"

    refute File.exists?(db)
    File.write!(db, "not sqlite")

    capture_io(:stderr, fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 1 end)

    assert File.read!(db) == "not sqlite"
  end

  test "records pre-effect rejections, effective input and provider failure", %{db: db} do
    core = start_supervised!({EventCore, path: db})
    start_supervised!({Projector, core: core})
    {:ok, io} = StringIO.open("")
    {:ok, reporter} = Reporter.start_link(core: core, io: io, path: db)

    script = [
      Fake.tool_call("delegate", %{"instruction" => "do work"}, "missing-comment"),
      Fake.tool_call(
        "delegate",
        %{"agent" => "invented", "comment" => "do work"},
        "unknown-agent"
      ),
      {:error, :provider_offline}
    ]

    resolver = fn ctx ->
      Agents.resolve(ctx, %{chat: Map.put(Fake.new(script), :model, "fake"), max_retries: 0})
    end

    start_supervised!({Runtime, core: core, max_depth: 1, agents: resolver})
    assert {:error, {:run_failed, _}} = Runtime.request(core, "delegate")
    requests = EventCore.stream(core, 0, type: "model.call.requested")
    assert length(requests) == 3
    assert hd(requests).payload["messages"] |> hd() |> Map.fetch!("content") =~ "comment"

    assert hd(requests).payload["schemas"]
           |> hd()
           |> get_in(["function", "parameters", "required"])
           |> Enum.member?("comment")

    tools = EventCore.stream(core, 0, type: "tool.call.completed")
    assert length(tools) == 2
    assert hd(tools).payload["output"] =~ "handoff_comment_required"
    assert List.last(tools).payload["output"] =~ "agent not in session"
    assert Enum.all?(tools, &(&1.payload["outcome"] == "error"))
    [failure] = EventCore.stream(core, 0, type: "model.call.failed")
    assert failure.causation_id == List.last(requests).event_id

    assert EventCore.query(
             core,
             "SELECT count(*) FROM WORK_ITEMS WHERE parent_work_item_id IS NOT NULL"
           ) == [[0]]

    Reporter.finish(reporter)

    output =
      capture_io(fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 0 end)

    assert tl(String.split(output, "\n")) ==
             tl(String.split(elem(StringIO.contents(io), 1), "\n"))

    assert output =~ "handoff_comment_required"
    assert output =~ "delivery.rejected"
  end

  test "run retains its log and refuses an existing destination", %{db: db, dir: dir} do
    config = Path.expand("../../fixtures/config/simple.toml", __DIR__)

    capture_io(:stderr, fn ->
      capture_io(fn ->
        assert CLI.dispatch(["run", dir, "conte até 3", "--db", db, "--config", config], %{}) == 0
      end)
    end)

    assert File.exists?(db)
    bytes = File.read!(db)

    capture_io(:stderr, fn ->
      assert CLI.dispatch(["run", dir, "conte até 3", "--db", db, "--config", config], %{}) == 2
    end)

    assert File.read!(db) == bytes

    assert capture_io(fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 0 end) =~
             "task.completed"
  end

  test "interleaved Runs, unknown events and long content survive replay", %{db: db} do
    core = start_supervised!({EventCore, path: db})
    large = String.duplicate("evidence", 2000)

    attrs = %{
      attempt: 1,
      depth: 0,
      agent_id: "worker",
      agent_kind: "worker",
      reason: "initial",
      tools: %{"granted" => []}
    }

    for id <- ["parent", "child"] do
      EventCore.append!(
        core,
        Envelope.event("run.started", run_id: id, causation_id: "external", payload: attrs)
      )
    end

    EventCore.append!(
      core,
      Envelope.event("run.completed",
        run_id: "child",
        causation_id: "external",
        payload: %{outcome: "reported", comment: large}
      )
    )

    events = EventCore.stream(core, 0)
    {:ok, io} = StringIO.open("")
    {:ok, reporter} = Reporter.start_link(io: io, mode: "Replay")
    for event <- events ++ [List.last(events)], do: Reporter.event(reporter, event)

    unknown = %{
      List.last(events)
      | type: "custom.observation",
        sequence: 4,
        run_id: nil,
        payload: %{"note" => "visible"}
    }

    Reporter.event(reporter, unknown)
    Reporter.finish(reporter)
    output = elem(StringIO.contents(io), 1)
    assert output =~ large
    assert length(String.split(output, large)) == 2
    assert output =~ "Run parent: no closure recorded"
    refute output =~ "Run child: no closure recorded"
    assert output =~ "custom.observation"
    refute output =~ "\e"
  end

  test "unsupported schema is refused without changing the log", %{db: db} do
    core = start_supervised!({EventCore, path: db})
    EventCore.append!(core, Envelope.command("session.created", payload: %{session_id: "s"}))

    EventCore.transaction(core, fn conn ->
      Store.exec!(conn, "UPDATE EVENTS SET schema_version = '999'")
    end)

    assert {:error, message} = Replay.read(db, fn _ -> flunk("unsupported event delivered") end)
    assert message =~ "unsupported event schema"
  end
end
