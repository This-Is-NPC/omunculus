# Run with: mise exec -- mix run scripts/validate_real_matrix.exs --preset presets/cloud.toml
# Optional: --rounds 3 --base complex --task count --timeout 300000
# Workspaces and reports are isolated; sessions share test/sessions.sqlite3 (override with --db).
alias Omunculus.{Config, Dotenv, EventCore, Runtime}
alias Omunculus.Runtime.Agents
alias Omunculus.Event.Envelope
alias Omunculus.EventCore.Projector

{opts, _, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      db: :string,
      preset: :string,
      rounds: :integer,
      base: :string,
      task: :string,
      timeout: :integer
    ]
  )

if invalid != [], do: raise("invalid matrix options")
preset = Path.expand(opts[:preset] || "presets/local.toml")
db = Path.expand(opts[:db] || "test/sessions.sqlite3")
File.mkdir_p!(Path.dirname(db))
rounds = opts[:rounds] || 1
timeout = opts[:timeout] || 180_000
bases = if opts[:base], do: [opts[:base]], else: ["simple", "medium", "complex"]
tasks = if opts[:task], do: [opts[:task]], else: ["count", "write"]

unless rounds > 0 and timeout > 0 and Enum.all?(tasks, &(&1 in ["count", "write"])) and
         Enum.all?(bases, &(&1 in ["simple", "medium", "complex"])),
       do: raise("invalid matrix bounds")

{:ok, file_env} = Dotenv.load(File.cwd!())
env = Map.merge(file_env, System.get_env())

root =
  Path.join(
    System.tmp_dir!(),
    "omunculus-real-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  )

File.mkdir_p!(root)
IO.puts("Real-provider evidence: #{root}")

results =
  for round <- 1..rounds,
      base <- bases,
      task <- tasks,
      lane <- [false, true] do
    dir = Path.join(root, "round-#{round}-#{base}-#{task}-#{lane}")
    File.mkdir_p!(dir)
    config_path = Path.join(dir, "omunculus.toml")
    File.cp!("test/fixtures/config/#{base}.toml", config_path)
    overlay = Path.join(dir, "provider.toml")
    body = File.read!(preset)
    body = if lane, do: body <> "\n" <> File.read!("test/fixtures/config/lane.toml"), else: body
    File.write!(overlay, body)
    {:ok, config} = Config.load(cwd: dir, config_file: overlay, env: env)
    for {_, ws} <- config.workspaces, path <- ws.roots, do: File.mkdir_p!(path)
    {:ok, checked} = Config.check(config)
    {:ok, core} = EventCore.start_link(path: db, interceptors: checked.interceptors)
    {:ok, projector} = Projector.start_link(core: core)
    session = Envelope.generate_id("session")

    EventCore.append!(
      core,
      Envelope.command("session.created",
        session_id: session,
        payload: %{
          session_id: session,
          scenario: "matrix",
          base: base,
          task: task,
          lane: lane,
          round: round,
          model: config.chat.model
        }
      )
    )

    depth = config.policy |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> 0 end)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        session_id: session,
        max_depth: depth,
        agents: Agents.resolver(provider: "chat", env: env),
        config: [cwd: dir, config_file: overlay, env: env]
      )

    IO.puts("Session: #{session}; database: #{db}")

    for {name, ws} <- config.workspaces do
      EventCore.append!(
        core,
        Omunculus.Event.Envelope.command("workspace.attached",
          session_id: session,
          payload: %{workspace_id: name, roots: ws.roots, teams: ws.teams}
        )
      )
    end

    EventCore.configure_interceptors(
      core,
      Omunculus.CLI.Session.execution_interceptors(core, checked, config)
    )

    {:ok, automations} =
      Omunculus.Automations.start_link(core: core, automations: checked.automations)

    instruction = if task == "count", do: "conte até 10", else: "escrever um README"
    profile = if task == "count", do: "count", else: "coding"
    started = System.monotonic_time(:millisecond)

    result =
      Omunculus.Runtime.request(core, instruction,
        session_id: session,
        workspace: "app",
        timeout: timeout,
        execution: %{cwd: dir, config_file: overlay, profile: profile, provider: "chat"}
      )

    settle = fn recur, remaining ->
      if is_pid(runtime) do
        if Omunculus.Runtime.runs(runtime) != %{} and remaining > 0 do
          Process.sleep(10)
          recur.(recur, remaining - 1)
        end
      end
    end

    settle.(settle, 100)
    Projector.sync_core(core)
    events = EventCore.stream(core, 0, session_id: session)

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
    runtime_idle = Omunculus.Runtime.runs(runtime) == %{}
    snapshot = Projector.snapshot(core)
    Projector.rebuild(projector)
    replay_equal = snapshot == Projector.snapshot(core)

    starts = Enum.filter(events, &(&1.type == "run.started"))
    depths = Enum.map(starts, & &1.payload["depth"]) |> Enum.uniq() |> Enum.sort()

    required_depth =
      config.policy |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> 0 end)

    full_depth = Enum.all?(0..required_depth, &(&1 in depths))

    model_ids =
      events
      |> Enum.filter(&(&1.type == "model.call.completed"))
      |> Enum.map(& &1.payload["model"])
      |> Enum.uniq()

    event_ids = MapSet.new(events, & &1.event_id)
    starts_by_id = Map.new(starts, &{&1.run_id, &1})

    causation_missing =
      Enum.count(events, &(&1.causation_id && not MapSet.member?(event_ids, &1.causation_id)))

    broken_parent_links =
      Enum.count(starts, fn start ->
        depth = start.payload["depth"]
        parent = starts_by_id[start.payload["parent_run_id"]]
        depth > 0 and (is_nil(parent) or parent.payload["depth"] != depth - 1)
      end)

    task_outcome =
      case result do
        {:ok, _} -> "completed"
        {:error, :timeout} -> "timeout"
        _ -> "error"
      end

    tool_errors =
      events
      |> Enum.filter(&(&1.type == "tool.call.completed" and &1.payload["outcome"] != "completed"))
      |> Enum.map(& &1.payload["outcome"])

    row = %{
      session_id: session,
      base: base,
      task: task,
      lane: lane,
      model: config.chat.model,
      observed_models: model_ids,
      preset: Path.basename(preset),
      round: round,
      depths: depths,
      full_depth: full_depth,
      runtime_idle: runtime_idle,
      contract_success:
        success and full_depth and replay_equal and runtime_idle and
          causation_missing == 0 and broken_parent_links == 0,
      task_outcome: task_outcome,
      causation_missing: causation_missing,
      broken_parent_links: broken_parent_links,
      tool_errors: tool_errors,
      run_failure_reasons:
        events |> Enum.filter(&(&1.type == "run.failed")) |> Enum.map(& &1.payload["reason"]),
      delegations: Enum.count(events, &(&1.type == "task.delegated")),
      continuations: Enum.count(starts, &(&1.payload["reason"] == "continuation")),
      tool_counts: Enum.frequencies_by(tools, & &1.payload["tool"]),
      run_failures: Enum.count(events, &(&1.type == "run.failed")),
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
    for pid <- [runtime, automations, projector, core], do: GenServer.stop(pid)
    row
  end

IO.puts(
  "Completed #{length(results)} cases; #{Enum.count(results, & &1.success)} achieved the requested result."
)
