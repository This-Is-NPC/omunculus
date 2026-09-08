defmodule Omunculus.MultiSessionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Omunculus.{CLI, EventCore, Runtime}
  alias Omunculus.CLI.Replay
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents
  alias Omunculus.Chat.Fake

  setup do
    db =
      Path.join(System.tmp_dir!(), "multi-session-#{System.unique_integer([:positive])}.sqlite3")

    core = start_supervised!({EventCore, path: db})
    projector = start_supervised!({Projector, core: core})

    for id <- ["alpha", "beta"] do
      EventCore.append!(
        core,
        Envelope.command("session.created", session_id: id, payload: %{session_id: id})
      )
    end

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(db <> suffix) end)
    %{db: db, core: core, projector: projector}
  end

  test "concurrent sessions share a database without crossing runs, policies or workspaces", %{
    db: db,
    core: core,
    projector: projector
  } do
    config = Path.expand("../fixtures/config/medium.toml", __DIR__)

    for id <- ["alpha", "beta"] do
      EventCore.append!(
        core,
        Envelope.command("workspace.attached",
          session_id: id,
          payload: %{workspace_id: "app", roots: ["/tmp/" <> id]}
        )
      )

      start_supervised!(
        Supervisor.child_spec(
          {Runtime,
           core: core,
           session_id: id,
           max_depth: 1,
           agents: Agents.resolver(),
           recover: true,
           config: [cwd: File.cwd!(), config_file: config, profile: "count"],
           run_opts: [fs: Omunculus.FS.Memory.new()]},
          id: {:runtime, id}
        )
      )
    end

    tasks =
      for {id, n} <- [{"alpha", 3}, {"beta", 5}] do
        Task.async(fn ->
          Runtime.request(core, "conte até #{n}", session_id: id, workspace: "app")
        end)
      end

    assert Enum.map(tasks, &Task.await/1) |> Enum.map(fn {:ok, r} -> r.result end) == ["3", "5"]
    Projector.sync(projector)

    for {id, n} <- [{"alpha", 3}, {"beta", 5}] do
      events = EventCore.stream(core, 0, session_id: id)

      values =
        for e <- events,
            e.type == "tool.call.completed" and e.payload["tool"] == "counter" and
              e.payload["outcome"] == "completed",
            do: e.payload["new"]

      assert values == Enum.to_list(1..n)
      assert Enum.count(events, &(&1.type == "policy.loaded")) == 1
      root = Enum.find(events, &(&1.type == "task.requested"))
      all = EventCore.stream(core, 0, correlation_id: root.correlation_id)
      assert Enum.all?(all, &(&1.session_id == id))

      assert EventCore.query(
               core,
               "SELECT roots FROM SESSION_WORKSPACES WHERE session_id = ? AND workspace_id = 'app'",
               [id]
             ) == [[Jason.encode!(["/tmp/" <> id])]]

      captured =
        capture_io(fn -> assert CLI.dispatch(["session", "replay", id, "--db", db], %{}) == 0 end)

      refute captured =~ if(id == "alpha", do: "Session: beta", else: "Session: alpha")
    end

    EventCore.append!(
      core,
      Envelope.command("workspace.detached", session_id: "alpha", payload: %{workspace_id: "app"})
    )

    Projector.sync(projector)

    assert EventCore.query(
             core,
             "SELECT session_id, attached FROM SESSION_WORKSPACES ORDER BY session_id"
           ) == [["alpha", 0], ["beta", 1]]

    snapshot = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == snapshot
  end

  test "starting another runtime does not process a session awaiting human review", %{core: core} do
    resolver = fn ctx ->
      Agents.resolve(ctx, %{
        chat:
          Fake.new([Fake.text(~s({"completed":false,"break":true,"comment":"alpha needs human"}))])
          |> Map.put(:model, "fake")
      })
    end

    runtime =
      start_supervised!(
        Supervisor.child_spec(
          {Runtime, core: core, session_id: "alpha", max_depth: 0, agents: resolver},
          id: :alpha_runtime
        )
      )

    assert {:error, {:awaiting_human, _}} =
             Runtime.request(core, "review alpha", session_id: "alpha", return_on_human: true)

    GenServer.stop(runtime)
    before = EventCore.stream(core, 0, session_id: "alpha")

    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         core: core, session_id: "beta", max_depth: 0, recover: true, agents: Agents.resolver()},
        id: :beta_runtime
      )
    )

    assert {:ok, %{result: "2"}} = Runtime.request(core, "conte até 2", session_id: "beta")
    assert EventCore.stream(core, 0, session_id: "alpha") == before
  end

  test "replay requires an identity, rejects unknown sessions and session list includes every identity",
       %{db: db} do
    capture_io(:stderr, fn -> assert CLI.dispatch(["session", "replay", "--db", db], %{}) == 2 end)

    assert {:error, message} = Replay.read(db, "absent", fn _ -> flunk("wrong session") end)
    assert message =~ "unknown session"

    assert capture_io(fn -> assert CLI.dispatch(["session", "list", "--db", db], %{}) == 0 end) ==
             "alpha\nbeta\n"
  end

  test "a workspace attached only elsewhere cannot authorize a session", %{core: core} do
    EventCore.append!(
      core,
      Envelope.command("workspace.attached",
        session_id: "alpha",
        payload: %{workspace_id: "private", roots: ["/tmp/alpha"]}
      )
    )

    request =
      Envelope.command("task.requested",
        session_id: "beta",
        payload: %{instruction: "work", workspace: "private"}
      )

    assert {:ok, {:reject, "workspace not attached"}} =
             EventCore.transaction(core, fn conn ->
               Omunculus.Interceptors.WorkspaceGate.intercept(request, %{
                 conn: conn,
                 attached: ["private"]
               })
             end)
  end
end
