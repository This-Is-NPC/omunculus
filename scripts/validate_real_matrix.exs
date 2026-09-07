# Run with: mise exec -- mix run scripts/validate_real_matrix.exs
# Every workspace, database and output is isolated under a new /tmp directory.
alias Omunculus.{Config, EventCore, SessionExecutor}
alias Omunculus.EventCore.Projector

root =
  Path.join(
    System.tmp_dir!(),
    "omunculus-real-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  )

File.mkdir_p!(root)
IO.puts("Real-provider evidence: #{root}")

results =
  for base <- ["simple", "medium", "complex"],
      task <- ["count", "write"],
      lane <- [false, true] do
    dir = Path.join(root, "#{base}-#{task}-#{lane}")
    File.mkdir_p!(dir)
    config_path = Path.join(dir, "omunculus.toml")
    File.cp!("test/fixtures/config/#{base}.toml", config_path)
    overlay = Path.join(dir, "provider.toml")
    body = File.read!("presets/local.toml")
    body = if lane, do: body <> "\n" <> File.read!("test/fixtures/config/lane.toml"), else: body
    File.write!(overlay, body)
    {:ok, config} = Config.load(cwd: dir, config_file: overlay, env: %{})
    for {_, ws} <- config.workspaces, path <- ws.roots, do: File.mkdir_p!(path)
    db = Path.join(dir, "session.sqlite3")

    {:ok, owner} =
      SessionExecutor.ensure_started(db: db, cwd: dir, config_file: overlay, provider: "chat")

    core = SessionExecutor.core(owner)

    session =
      EventCore.stream(core, 0, type: "session.created")
      |> hd()
      |> Map.get(:payload)
      |> Map.fetch!("session_id")

    for {name, ws} <- config.workspaces do
      EventCore.append!(
        core,
        Omunculus.Event.Envelope.command("workspace.attached",
          session_id: session,
          payload: %{workspace_id: name, roots: ws.roots, teams: ws.teams}
        )
      )
    end

    instruction = if task == "count", do: "conte até 10", else: "escrever um README"
    profile = if task == "count", do: "count", else: "coding"
    started = System.monotonic_time(:millisecond)

    result =
      Omunculus.Runtime.request(core, instruction,
        session_id: session,
        workspace: "app",
        timeout: 180_000,
        execution: %{cwd: dir, config_file: overlay, profile: profile, provider: "chat"}
      )

    settle = fn recur, remaining ->
      runtime = :sys.get_state(owner).runtime

      if is_pid(runtime) do
        if Omunculus.Runtime.runs(runtime) != %{} and remaining > 0 do
          Process.sleep(10)
          recur.(recur, remaining - 1)
        end
      end
    end

    settle.(settle, 100)
    Projector.sync_core(core)
    events = EventCore.stream(core, 0)

    tools =
      Enum.filter(
        events,
        &(&1.type == "tool.call.completed" and &1.payload["outcome"] == "completed")
      )

    readme = Path.join(hd(config.workspaces["app"].roots), "README.md")

    actual =
      if task == "count",
        do: Enum.count(tools, &(&1.payload["tool"] == "counter")),
        else: File.exists?(readme)

    expected = if task == "count", do: 10, else: true
    success = match?({:ok, _}, result) and actual == expected
    snapshot = Projector.snapshot(core)
    Projector.rebuild(:sys.get_state(owner).projector)
    replay_equal = snapshot == Projector.snapshot(core)

    row = %{
      base: base,
      task: task,
      lane: lane,
      model: "qwen3.5:4b",
      success: success,
      actual: actual,
      replay_equal: replay_equal,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      result: inspect(result, limit: 5),
      events: length(events),
      db: db
    }

    File.write!(Path.join(root, "results.ndjson"), Jason.encode!(row) <> "\n", [:append])
    IO.puts(Jason.encode!(row))
    SessionExecutor.stop(owner)
    row
  end

IO.puts(
  "Completed #{length(results)} cases; #{Enum.count(results, & &1.success)} achieved the requested result."
)
