defmodule Omunculus.CLI.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Omunculus.CLI.Parser
  alias Omunculus.EventCore

  @fixtures Path.expand("../../fixtures/config", __DIR__)

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    db =
      Path.join(
        System.tmp_dir!(),
        "omunculus-session-test-#{suffix}.sqlite3"
      )

    on_exit(fn -> File.rm(db) end)
    %{db: db}
  end

  test "session create writes session.created and prints the id", %{db: db} do
    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(["session", "create", "test-session", "--db", db], %{}) == 0
      end)

    assert String.trim(out) == "test-session"

    {:ok, core} = EventCore.start_link(path: db)
    [env] = EventCore.stream(core, 0, type: "session.created")
    assert env.payload["session_id"] == "test-session"
    GenServer.stop(core)
  end

  test "send counts to three with medium config", %{db: db} do
    config = Path.join(@fixtures, "medium.toml")

    assert Omunculus.CLI.dispatch(["session", "create", "s1", "--db", db], %{}) == 0

    assert Omunculus.CLI.dispatch(
             ["workspace", "attach", "app", "--db", db, "--config", config],
             %{}
           ) == 0

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(
                 [
                   "send",
                   "conte até 3",
                   "--db",
                   db,
                   "--config",
                   config,
                   "--profile",
                   "count"
                 ],
                 %{}
               ) == 0
      end)

    assert String.trim(out) == "3"
  end

  test "workspace attach rejects unknown workspace", %{db: db} do
    config = Path.join(@fixtures, "medium.toml")

    assert Omunculus.CLI.dispatch(["session", "create", "s1", "--db", db], %{}) == 0

    err =
      capture_io(:stderr, fn ->
        assert Omunculus.CLI.dispatch(
                 ["workspace", "attach", "missing", "--db", db, "--config", config],
                 %{}
               ) == 2
      end)

    assert err =~ "unknown workspace"
  end

  test "parser accepts session list" do
    assert {:ok, %{command: :session, args: %{action: "list"}}} =
             Parser.parse(["session", "list", "--db", "/tmp/x.db"], %{})
  end

  test "session create with --session writes session.created to that file" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    db = Path.join(System.tmp_dir!(), "omunculus-session-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(db) end)

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(["session", "create", "via-session", "--session", db], %{}) ==
                 0
      end)

    assert String.trim(out) == "via-session"

    {:ok, core} = EventCore.start_link(path: db)
    [env] = EventCore.stream(core, 0, type: "session.created")
    assert env.payload["session_id"] == "via-session"
    GenServer.stop(core)
  end

  test "OMUNCULUS_SESSION selects the session sqlite file via dispatch env" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    db = Path.join(System.tmp_dir!(), "omunculus-session-env-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(db) end)

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(["session", "create", "from-env"], %{
                 "OMUNCULUS_SESSION" => db
               }) == 0
      end)

    assert String.trim(out) == "from-env"
    assert File.exists?(db)
  end

  test "events follow --once --session prints session.created after create" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    db = Path.join(System.tmp_dir!(), "omunculus-follow-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(db) end)

    assert Omunculus.CLI.dispatch(["session", "create", "follow-me", "--session", db], %{}) == 0

    out =
      capture_io(fn ->
        assert Omunculus.CLI.dispatch(["events", "follow", "--once", "--session", db], %{}) == 0
      end)

    assert out =~ "session.created"
    assert out =~ "follow-me"
  end
end
