# Protocol v2 diagnostic: the first child requests break with an incomplete report.
# All other responses come from the selected real provider. No repository writes.
# Run: mise exec -- mix run scripts/validate_parent_review.exs presets/local.toml
alias Omunculus.{Config, Dotenv, EventCore, Runtime}
alias Omunculus.EventCore.Projector
alias Omunculus.Runtime.Agents

[preset] = System.argv()
{:ok, file_env} = Dotenv.load(File.cwd!())
env = Map.merge(file_env, System.get_env())

dir =
  Path.join(System.tmp_dir!(), "omunculus-review-" <> Base.encode16(:crypto.strong_rand_bytes(5)))

File.mkdir_p!(dir)
File.cp!("test/fixtures/config/complex.toml", Path.join(dir, "omunculus.toml"))
overlay = Path.join(dir, "provider.toml")
File.write!(overlay, File.read!(preset) <> "\n" <> File.read!("test/fixtures/config/lane.toml"))
{:ok, config} = Config.load(cwd: dir, config_file: overlay, env: env)
{:ok, checked} = Config.check(config)

{:ok, core} =
  EventCore.start_link(
    path: Path.join(dir, "session.sqlite3"),
    interceptors: checked.interceptors
  )

{:ok, projector} = Projector.start_link(core: core)
{:ok, injected} = Agent.start_link(fn -> false end)

resolver = fn ctx ->
  inject? =
    ctx.depth == 1 and ctx.reason == "initial" and
      Agent.get_and_update(injected, fn used -> {not used, true} end)

  if inject? do
    chat =
      Omunculus.Chat.Fake.new([
        Omunculus.Chat.Fake.text(
          Jason.encode!(%{
            completed: false,
            break: true,
            comment:
              "Incomplete: I did not call counter. No measured result or evidence is available."
          })
        )
      ])
      |> Map.put(:model, "injected-incomplete-report")

    Agents.resolve(ctx, %{chat: chat})
  else
    Agents.resolve(ctx, %{provider: "chat", env: env})
  end
end

{:ok, runtime} =
  Runtime.start_link(
    core: core,
    max_depth: 2,
    agents: resolver,
    config: [cwd: dir, config_file: overlay, profile: "count", env: env],
    run_opts: [fs: Omunculus.FS.Memory.new()]
  )

IO.puts("Parent review evidence: #{dir}")
started = System.monotonic_time(:millisecond)

result =
  Runtime.request(
    core,
    "Use a ferramenta counter para contar de zero até 3. Informe o valor obtido.",
    workspace: "app",
    timeout: 180_000
  )

# Stop the sole writer before collecting, including on client timeout.
GenServer.stop(runtime)
Projector.sync(projector)
events = EventCore.stream(core, 0)
starts = Enum.filter(events, &(&1.type == "run.started"))
depths = Map.new(starts, &{&1.run_id, &1.payload["depth"]})
delegations = Enum.filter(events, &(&1.type == "task.delegated"))
root_requests = Enum.filter(delegations, &(depths[&1.run_id] == 0))

report =
  Enum.find(
    events,
    &(&1.type == "run.completed" and
        get_in(&1.payload, ["report", "comment"]) ==
          "Incomplete: I did not call counter. No measured result or evidence is available.")
  )

accepted =
  Enum.filter(root_requests, fn request ->
    Enum.any?(starts, &(&1.work_item_id == request.payload["child_work_item_id"]))
  end)

corrections =
  Enum.filter(events, fn event ->
    cause = Enum.find(events, &(&1.event_id == event.causation_id))

    event.type == "task.retry_requested" and report != nil and event.sequence > report.sequence and
      cause != nil and cause.type == "run.completed" and depths[cause.run_id] == 0
  end)

sequences =
  events
  |> Enum.filter(
    &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter" and
        &1.payload["outcome"] == "completed")
  )
  |> Enum.group_by(& &1.work_item_id)
  |> Map.values()
  |> Enum.map(fn calls -> Enum.map(calls, & &1.payload["new"]) end)
  |> Enum.sort()

row = %{
  protocol: 2,
  retries: Enum.count(starts, &(&1.payload["reason"] == "retry")),
  break_reviews: Enum.count(starts, &(&1.payload["reason"] == "break")),
  breaks: Enum.count(events, &(&1.type == "task.break")),
  human_requests:
    Enum.count(events, &(&1.type == "task.commented" and &1.payload["kind"] == "request")),
  preset: Path.basename(preset),
  model: config.chat.model,
  incomplete_report_injected: Agent.get(injected, & &1),
  root_delegations: length(root_requests),
  accepted_root_delegations: length(accepted),
  corrections_after_report: length(corrections),
  rejections:
    events |> Enum.filter(&(&1.type == "delivery.rejected")) |> Enum.map(& &1.payload["reason"]),
  root_instructions: Enum.map(root_requests, & &1.payload["instruction"]),
  client_success: match?({:ok, _}, result),
  root_result:
    case result do
      {:ok, value} -> value.result
      {:error, reason} -> inspect(reason)
    end,
  counter_sequences: sequences,
  correction_cycle_observed:
    report != nil and corrections != [] and [1, 2, 3] in sequences and
      match?({:ok, _}, result),
  continuations: Enum.count(starts, &(&1.payload["reason"] == "continuation")),
  failures: Enum.count(events, &(&1.type == "run.failed")),
  elapsed_ms: System.monotonic_time(:millisecond) - started
}

File.write!(Path.join(dir, "result.json"), Jason.encode!(row, pretty: true))
IO.puts(Jason.encode!(row))
for pid <- [projector, core, injected], do: GenServer.stop(pid)
