defmodule Omunculus.CLI.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Omunculus.CLI.Parser
  alias Omunculus.EventCore

  @fixtures Path.expand("../../fixtures/config", __DIR__)

  setup do
    db =
      Path.join(
        System.tmp_dir!(),
        "omunculus-session-test-#{System.unique_integer([:positive])}.sqlite3"
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
end
