# Real-provider interception scenario. Ends only on root completion or human intervention.
# mise exec -- mix run scripts/validate_interception.exs presets/local.toml [--db test/sessions.sqlite3] [--output /tmp/interception-result.json]
alias Omunculus.{Config, Dotenv, EventCore, Runtime}
alias Omunculus.Event.Envelope
alias Omunculus.EventCore.Projector
alias Omunculus.Runtime.Agents
{opts, [preset], []} = OptionParser.parse(System.argv(), strict: [db: :string, output: :string])
{:ok, file_env} = Dotenv.load(File.cwd!())
env = Map.merge(file_env, System.get_env())
dir = Path.join(System.tmp_dir!(), "interception-real-" <> Envelope.generate_id("case"))
File.mkdir_p!(dir)
file = Path.join(dir, "omunculus.toml")

File.write!(
  file,
  File.read!(preset) <>
    "\n" <>
    File.read!("examples/interception-agent.toml") <>
    """

    [agents.worker]
    prompt = "Execute only the assigned work. Use counter exactly once, then report its actual returned value. The counter takes no arguments."
    tools = ["counter"]
    workflow = "delivery"
    max_retries = 1
    [agents.reviewer]
    prompt = "Review the supplied handoff context and recorded tool state. Do not repeat execution. State whether the requested one increment is confirmed."
    tools = []
    max_retries = 1
    [workflows.delivery]
    steps = [
      {name = "implement", instructions = "Call counter exactly once, reaching 1. Report the actual value."},
      {name = "review", agent = "reviewer", instructions = "Verify the previous evidence confirms exactly one counter call and value 1. Do not execute the counter again."}
    ]
    """
)

{:ok, config} = Config.load(cwd: dir, config_file: file, env: env)
{:ok, checked} = Config.check(config)
db = Path.expand(opts[:db] || "test/sessions.sqlite3")
{:ok, core} = EventCore.start_link(path: db, interceptors: checked.interceptors)
{:ok, projector} = Projector.start_link(core: core)
session = Envelope.generate_id("session")

EventCore.append!(
  core,
  Envelope.command("session.created",
    session_id: session,
    payload: %{session_id: session, scenario: "agent_interception", model: config.chat.model}
  )
)

{:ok, runtime} =
  Runtime.start_link(
    core: core,
    session_id: session,
    max_depth: 0,
    agents: Agents.resolver(provider: "chat", env: env),
    config: [cwd: dir, config_file: file, env: env],
    run_opts: [fs: Omunculus.FS.Memory.new()]
  )

EventCore.subscribe(core, session_id: session)

root =
  EventCore.append!(
    core,
    Envelope.command("task.requested",
      session_id: session,
      work_item_id: Envelope.generate_id("wi"),
      payload: %{
        instruction:
          "Increment counter exactly once to 1, then review the recorded evidence without repeating the action."
      }
    )
  )

IO.puts("Session: #{session}; root: #{root.work_item_id}; configuration: #{file}")
started = System.monotonic_time(:millisecond)

await = fn await ->
  receive do
    {:event_core, %{type: "task.completed", work_item_id: wi} = e} when wi == root.work_item_id ->
      {:completed, e}

    {:event_core, %{type: "interception.requested", payload: %{"actor" => "human"}} = e} ->
      {:awaiting_human, e}

    {:event_core,
     %{
       type: "task.commented",
       correlation_id: corr,
       payload: %{"assessment" => true, "kind" => "request"}
     } = e}
    when corr == root.correlation_id ->
      {:awaiting_human, e}

    {:event_core, _} ->
      await.(await)
  end
end

{outcome, terminal} = await.(await)
elapsed = System.monotonic_time(:millisecond) - started
# In this scenario the actor has no tools and no configured transport deadline;
# observing completion/intervention means its producer Runs have closed.
GenServer.stop(runtime)
Projector.sync(projector)
events = EventCore.stream(core, 0, session_id: session)
requests = Enum.filter(events, &(&1.type == "interception.requested"))
resolutions = Enum.filter(events, &(&1.type == "interception.resolved"))
starts = Enum.filter(events, &(&1.type == "run.started"))
finishes = Enum.filter(events, &(&1.type in ["run.completed", "run.failed"]))

effects =
  Enum.filter(
    events,
    &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter" and
        &1.payload["outcome"] == "completed")
  )

review = Enum.find(starts, &(&1.payload["agent_id"] == "reviewer"))

review_call =
  if review,
    do: Enum.find(events, &(&1.type == "model.call.requested" and &1.run_id == review.run_id))

first = List.first(resolutions)

forwarded =
  first && review_call &&
    Enum.any?(
      review_call.payload["messages"],
      &String.contains?(&1["content"] || "", first.payload["output"]["comment"])
    )

snapshot = Projector.snapshot(core)
Projector.rebuild(projector)

result = %{
  runtime_fingerprint:
    Path.wildcard("lib/**/*.ex")
    |> Enum.sort()
    |> Enum.map(fn path -> [path, File.read!(path)] end)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower),
  session_id: session,
  database: db,
  model: config.chat.model,
  protocol_outcome: outcome,
  elapsed_ms: elapsed,
  runs: length(starts),
  actor_requests: length(requests),
  resolutions: length(resolutions),
  effects: Enum.map(effects, & &1.payload["new"]),
  summary_received_by_reviewer: forwarded == true,
  reviewer_started_after_resolution: first && review && first.sequence < review.sequence,
  all_runs_closed: Enum.all?(starts, fn s -> Enum.any?(finishes, &(&1.run_id == s.run_id)) end),
  replay_equal: snapshot == Projector.snapshot(core),
  terminal_event_id: terminal.event_id,
  events: Enum.map(events, &Envelope.to_map/1)
}

File.write!(opts[:output] || "/tmp/interception-result.json", Jason.encode!(result, pretty: true))
IO.puts(Jason.encode!(Map.delete(result, :events)))
for pid <- [projector, core], do: GenServer.stop(pid)
