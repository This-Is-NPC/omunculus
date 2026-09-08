# Independent real-provider cases; the effect oracle only measures results.
# Usage: mise exec -- mix run scripts/validate_workflow.exs presets/cloud.toml [plain|staged] [--db test/sessions.sqlite3] [--depth 1|2] [--repeats 1]
# Duration is a metric. Human escalation is a pending decision, not task failure.
alias Omunculus.{Config, Dotenv, EventCore, Runtime}
alias Omunculus.EventCore.Projector
alias Omunculus.Runtime.Agents
alias Omunculus.Event.Envelope
Code.require_file("support/workflow_observer.exs", __DIR__)

{options, [preset | selected], []} =
  OptionParser.parse(System.argv(), strict: [db: :string, depth: :integer, repeats: :integer])

depth = options[:depth] || 1
repeats = options[:repeats] || 1
true = depth in [1, 2] and repeats > 0
db = Path.expand(options[:db] || "test/sessions.sqlite3")
File.mkdir_p!(Path.dirname(db))
{:ok, core} = EventCore.start_link(path: db)
{:ok, projector} = Projector.start_link(core: core)
cases = if selected == [], do: ["plain", "staged"], else: selected
true = Enum.all?(cases, &(&1 in ["plain", "staged"]))
{:ok, file_env} = Dotenv.load(File.cwd!())
env = Map.merge(file_env, System.get_env())

root =
  Path.join(System.tmp_dir!(), "omunculus-stages-" <> Base.encode16(:crypto.strong_rand_bytes(5)))

File.mkdir_p!(root)
IO.puts("Evidence: #{root}; database: #{db}")

rows =
  for repetition <- 1..repeats, scenario <- cases do
    staged = scenario == "staged"
    dir = Path.join(root, "#{repetition}-#{scenario}")
    File.mkdir_p!(dir)
    base = File.read!("test/fixtures/config/medium.toml")

    base =
      if depth == 2 do
        String.replace(
          base,
          "[policy.depth.1]\nmode = \"allow\"\ndeny = [\"delegate\"]",
          "[policy.depth.1]\nmode = \"deny\"\ngranted = [\"delegate\"]\n\n[policy.depth.2]\nmode = \"allow\"\ndeny = [\"delegate\"]"
        )
      else
        base
      end

    File.write!(Path.join(dir, "omunculus.toml"), base)
    overlay = Path.join(dir, "provider.toml")

    workflow =
      if staged do
        """
        [workflows.delivery]
        steps = [
          {name = "in_progress", instructions = "Increment counter exactly three times, reaching 3. Record each returned value as evidence."},
          {name = "review", agent = "reviewer", instructions = "Verify the recorded evidence against the task. Do not increment counter again. Report whether the confirmed final value is 3."}
        ]
        [agents.worker]
        workflow = "delivery"
        """
      else
        ""
      end

    File.write!(overlay, File.read!(preset) <> "\n" <> workflow)
    {:ok, config} = Config.load(cwd: dir, config_file: overlay, env: env)
    {:ok, _} = Config.check(config)
    session_id = Envelope.generate_id("session")

    EventCore.append!(
      core,
      Envelope.command("session.created",
        session_id: session_id,
        payload: %{
          session_id: session_id,
          scenario: scenario,
          repetition: repetition,
          required_depth: depth,
          model: config.chat.model
        }
      )
    )

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        session_id: session_id,
        max_depth: depth,
        agents: Agents.resolver(provider: "chat", env: env),
        config: [cwd: dir, config_file: overlay, profile: "count", env: env],
        run_opts: [fs: Omunculus.FS.Memory.new()]
      )

    started = System.monotonic_time(:millisecond)

    :ok = EventCore.subscribe(core, session_id: session_id)

    requested =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          session_id: session_id,
          work_item_id: Envelope.generate_id("wi"),
          payload: %{
            instruction:
              "Delegate through #{depth} level(s), with only the final worker executing counter: increment counter exactly three times, reaching 3. Every parent must review actual returned values before approving. Report the final value and evidence.",
            depth: 0,
            execution: %{},
            workspace: "app"
          }
        )
      )

    IO.puts(
      "Started #{scenario}: session=#{session_id}, root=#{requested.work_item_id}; waiting for protocol outcome"
    )

    {outcome, terminal} = Omunculus.WorkflowObserver.await(requested.work_item_id)
    elapsed_ms = System.monotonic_time(:millisecond) - started
    EventCore.unsubscribe(core)

    GenServer.stop(runtime)
    Projector.sync(projector)
    events = EventCore.stream(core, 0, session_id: session_id)
    starts = Enum.filter(events, &(&1.type == "run.started"))

    values =
      events
      |> Enum.filter(
        &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter" and
            &1.payload["outcome"] == "completed")
      )
      |> Enum.map(& &1.payload["new"])

    assessments = Enum.filter(events, &(&1.type == "task.assessment_requested"))
    done = Enum.filter(events, &(&1.type == "task.completed"))
    advances = Enum.filter(events, &(&1.type == "task.advanced"))
    by_id = Map.new(events, &{&1.event_id, &1})

    approvals_valid =
      Enum.all?(done ++ advances, fn event ->
        cause = by_id[event.causation_id]

        cause && cause.type == "run.completed" &&
          get_in(cause.payload, ["report", "completed"]) == true &&
          (cause.work_item_id == event.work_item_id ||
             get_in(cause.payload, ["assessment", "target"]) == event.work_item_id)
      end)

    starts_by_id = Map.new(starts, &{&1.run_id, &1})
    finishes = Enum.filter(events, &(&1.type in ["run.completed", "run.failed"]))
    closed_runs = MapSet.new(finishes, & &1.run_id)

    productive =
      Enum.filter(
        events,
        &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter" and
            &1.payload["outcome"] == "completed")
      )

    effect_owners = Enum.uniq(Enum.map(productive, & &1.work_item_id))

    effect_depths =
      Enum.uniq(Enum.map(productive, fn e -> starts_by_id[e.run_id].payload["depth"] end))

    lineage_valid =
      Enum.all?(starts, fn e ->
        parent = starts_by_id[e.payload["parent_run_id"]]

        e.payload["depth"] == 0 or
          (parent != nil and parent.payload["depth"] == e.payload["depth"] - 1)
      end)

    tools_recorded = Enum.all?(starts, &is_list(&1.payload["available_tools"]))

    schemas_match =
      Enum.all?(starts, fn e ->
        call = Enum.find(events, &(&1.type == "model.call.requested" and &1.run_id == e.run_id))

        is_nil(call) or
          Enum.sort(e.payload["available_tools"]) ==
            Enum.sort(Enum.map(call.payload["schemas"], &get_in(&1, ["function", "name"])))
      end)

    all_runs_closed = Enum.all?(starts, &MapSet.member?(closed_runs, &1.run_id))
    topology_valid = length(effect_owners) == 1 and effect_depths == [depth] and lineage_valid
    before = Projector.snapshot(core)
    Projector.rebuild(projector)

    delegations = Enum.filter(events, &(&1.type == "task.delegated"))

    handoffs_valid =
      Enum.all?(delegations, fn event ->
        match?({:ok, _}, Omunculus.WorkItem.handoff(event.payload)) and
          Enum.any?(
            starts,
            &(&1.work_item_id == event.payload["child_work_item_id"] and
                &1.payload["work_item"] == event.payload["work_item"])
          )
      end)

    recoveries = Enum.filter(events, &(&1.type == "task.recovery_used"))

    recovery_bounded =
      recoveries
      |> Enum.group_by(&{&1.work_item_id, get_in(&1.payload, ["recovery", "stage"])})
      |> Enum.all?(fn {_, reservations} ->
        length(reservations) <= hd(reservations).payload["recovery"]["max_retries"]
      end)

    row = %{
      session_id: session_id,
      database: db,
      preset: Path.basename(preset),
      model: config.chat.model,
      staged: staged,
      repetition: repetition,
      required_depth: depth,
      protocol_outcome: outcome,
      root_completed: outcome == :completed,
      task_success: outcome == :completed and values == [1, 2, 3] and topology_valid,
      handoffs_valid: handoffs_valid,
      recovery_bounded: recovery_bounded,
      recoveries: length(recoveries),
      lineage_valid: lineage_valid,
      topology_valid: topology_valid,
      effect_owners: effect_owners,
      effect_depths: effect_depths,
      tools_recorded: tools_recorded,
      schemas_match: schemas_match,
      all_runs_closed: all_runs_closed,
      model_calls: Enum.count(events, &(&1.type == "model.call.completed")),
      effect_success: values == [1, 2, 3],
      result: terminal.payload["result"],
      terminal_event_id: terminal.event_id,
      human_request: if(outcome == :awaiting_human, do: terminal.payload["body"]),
      approvals_checked: length(done ++ advances),
      approvals_valid: approvals_valid,
      replay_equal: before == Projector.snapshot(core),
      counter_values: values,
      assessments: length(assessments),
      advances: length(advances),
      completed_items: length(done),
      runs: length(starts),
      reasons: Enum.frequencies_by(starts, & &1.payload["reason"]),
      failures: Enum.count(events, &(&1.type == "run.failed")),
      breaks: Enum.count(events, &(&1.type == "task.break")),
      elapsed_ms: elapsed_ms
    }

    File.write!(Path.join(dir, "result.json"), Jason.encode!(row, pretty: true))
    IO.puts(Jason.encode!(row))
    row
  end

File.write!(Path.join(root, "results.json"), Jason.encode!(rows, pretty: true))

for pid <- [projector, core], do: GenServer.stop(pid)
