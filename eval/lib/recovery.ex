defmodule EquivalentExchange.Recovery do
  @moduledoc "Replays a saved coordination stall with and without the experimental steward overlay."
  alias EquivalentExchange.{Project, Usage}
  alias Omunculus.{Config, Store}

  @repo Path.expand("../..", __DIR__)

  def worker(project) do
    File.write!(Path.join(project, "worker.pid"), System.pid())

    case Omunculus.CLI.run(["--config", Path.join(project, "omunculus.toml"), "config"], project) do
      {:ok, _output} -> :ok
      {:error, reason} -> raise Omunculus.CLI.format_error(reason)
    end
  end

  def run(options) do
    source = options |> Keyword.fetch!(:source) |> Path.expand()
    repetitions = Keyword.get(options, :k, 3)
    budget = Keyword.get(options, :budget, 20)
    overlay = options |> Keyword.fetch!(:overlay) |> Path.expand()
    if repetitions < 1 or budget < 1, do: raise(ArgumentError, "k and budget must be positive")
    manifest = source |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    snapshot = Path.join(source, "run-context/coordination-loop-at-cancellation.sqlite3")

    unless File.regular?(snapshot),
      do: raise(ArgumentError, "source needs its frozen cancellation snapshot")

    source_project =
      Path.join(source, "executions/design-team__conversation__design-to-build/agency/1/project")

    folder =
      Path.join(
        @repo,
        "eval/results/#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}-course-recovery"
      )

    temp = Path.join(@repo, ".temp/course-recovery/replays")
    File.mkdir_p!(folder)
    File.mkdir_p!(temp)

    write_json(Path.join(folder, "manifest.json"), %{
      source: Path.relative_to(source, @repo),
      snapshot: Path.relative_to(snapshot, @repo),
      overlay: Path.relative_to(overlay, @repo),
      repetitions: repetitions,
      response_budget: budget,
      started_at: DateTime.utc_now(),
      scope:
        "Coordination recovery only; stop before answering the client or granting production.",
      deadline: "infinity",
      order: "control then supervised for odd repetitions; reversed for even repetitions"
    })

    trials =
      for n <- 1..repetitions,
          arm <- if(rem(n, 2) == 1, do: ~w(control supervised), else: ~w(supervised control)),
          do: {n, arm}

    rows =
      Enum.map(trials, fn {n, arm} ->
        result = trial(temp, folder, n, arm, manifest, snapshot, source_project, overlay, budget)

        IO.puts(
          "#{arm} #{n}: #{result.status}, #{result.model_calls} responses, $#{Float.round(result.cost_usd, 6)}, #{Float.round(result.seconds, 1)} s"
        )

        result
      end)

    write_json(Path.join(folder, "summary.json"), %{trials: rows})

    text =
      [
        "# Steward recovery experiment",
        "",
        "Frozen hybrid coordination checkpoint; no client answer or deployment is executed.",
        "",
        "| Arm | Trial | Outcome | Model responses | Steward responses | USD | Seconds |",
        "|---|---:|---|---:|---:|---:|---:|"
      ] ++
        Enum.map(rows, fn r ->
          "| #{r.arm} | #{r.repetition} | #{r.status} | #{r.model_calls} | #{Map.get(r.calls_by_agent, "steward", 0)} | #{Float.round(r.cost_usd, 6)} | #{Float.round(r.seconds, 1)} |"
        end) ++
        [
          "",
          "The response budget bounds this diagnostic probe by recorded model responses, not elapsed time. Exhaustion is a censored observation, not a model latency failure. The original quality task and production checks are not scored by this experiment.",
          "",
          "Provider costs exclude local hardware. Models are stochastic; finite repetitions do not establish general quality. The new client request must be authored by sales and retain the original permission origins. No grant may be emitted."
        ]

    File.write!(Path.join(folder, "report.md"), Enum.join(text, "\n") <> "\n")
    File.rmdir(temp)
    IO.puts(folder)
    {:ok, folder}
  end

  defp trial(temp, folder, n, arm, manifest, snapshot, source_project, overlay, budget) do
    project = Path.join(temp, "#{arm}-#{n}")
    result = Path.join(folder, "#{arm}-#{n}")
    File.mkdir_p!(result)
    overrides = manifest["agent_models"] || %{}

    {:ok, path} =
      Project.build(
        project,
        "agency",
        {manifest["model"], manifest["code_mode"]},
        nil,
        overrides,
        if(arm == "supervised", do: overlay)
      )

    File.cp_r!(Path.join(source_project, "workspace"), Path.join(project, "workspace"))
    {:ok, config} = Config.load(path)
    File.mkdir_p!(Path.dirname(config.store.path))
    File.cp!(snapshot, config.store.path)
    File.cp!(path, Path.join(result, "omunculus.toml"))
    {:ok, opened} = Omunculus.Project.open(config, lock: false)
    initial = records(opened.conn)
    cursor = initial.events |> Enum.map(& &1.sequence) |> Enum.max(fn -> 0 end)
    {:ok, open_runs} = Store.open_runs(opened.conn)

    targets =
      open_runs
      |> Enum.flat_map(fn run ->
        if run.request_id do
          {:ok, request} = Store.view(opened.conn, "request", run.request_id)
          request |> leaves() |> Enum.reject(&(&1.status == "closed")) |> Enum.map(& &1.id)
        else
          []
        end
      end)
      |> MapSet.new()

    if MapSet.size(targets) == 0, do: raise("checkpoint has no unresolved original request")
    log = File.open!(Path.join(result, "worker.log"), [:write])
    started = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("setsid")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, @repo},
        {:args,
         [
           "--wait",
           System.find_executable("mise"),
           "exec",
           "--",
           "mix",
           "run",
           "eval/run.exs",
           "recovery-worker",
           project
         ]}
      ])

    try do
      {status, collected, client} = observe(port, log, opened.conn, cursor, targets, budget, %{})
      stop_worker(project)
      # Record any response that completed while shutdown was being delivered.
      final = records(opened.conn)

      collected =
        Enum.reduce(final.events, collected, fn e, acc ->
          if e.sequence > cursor, do: Map.put(acc, e.id, e), else: acc
        end)

      new_events = collected |> Map.values() |> Enum.sort_by(& &1.sequence)

      responses =
        Enum.filter(
          new_events,
          &(&1.type == "model" and is_map(&1.body) and is_map(&1.body["usage"]))
        )

      usage =
        Usage.summarize(
          %{events: responses, runs: final.runs},
          config,
          Toml.decode_file!(Path.join(@repo, "eval/prices.toml"))
        )

      agents = Map.new(final.runs, &{&1.id, &1.agent})
      grants = Enum.count(new_events, &(&1.type == "grant"))

      row = %{
        arm: arm,
        repetition: n,
        status: status,
        model_calls: length(responses),
        calls_by_agent: Enum.frequencies_by(responses, &agents[&1.run_id]),
        cost_usd: usage.cost,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        seconds: (System.monotonic_time(:millisecond) - started) / 1000,
        grants: grants,
        rejected_corrections:
          Enum.count(new_events, fn e ->
            e.type == "tool" and e.body["name"] == "correct_course" and
              e.body["ok"] == false
          end),
        client_request: client,
        original_requests: MapSet.to_list(targets)
      }

      if grants != 0, do: raise("probe unexpectedly emitted a grant")
      write_json(Path.join(result, "metrics.json"), row)

      File.write!(
        Path.join(result, "events.jsonl"),
        Enum.map_join(new_events, "\n", &Jason.encode!/1)
      )

      row
    after
      stop_worker(project)
      if Port.info(port), do: Port.close(port)
      File.close(log)
      Omunculus.Project.close(opened)
      erase(project)
    end
  end

  defp observe(port, log, conn, cursor, targets, budget, collected) do
    latest = records(conn)

    collected =
      Enum.reduce(latest.events, collected, fn e, acc ->
        if e.sequence > cursor, do: Map.put(acc, e.id, e), else: acc
      end)

    new = Map.values(collected)

    client = client_request(conn, new, targets)

    count =
      Enum.count(new, &(&1.type == "model" and is_map(&1.body) and is_map(&1.body["usage"])))

    cond do
      client ->
        {"recovered", collected, client.request_id}

      count >= budget ->
        {"response_budget_exhausted", collected, nil}

      true ->
        receive do
          {^port, {:data, data}} ->
            IO.binwrite(log, data)
            observe(port, log, conn, cursor, targets, budget, collected)

          {^port, {:exit_status, code}} ->
            # A settled worker may have just recorded the desired request.
            last = records(conn)

            collected =
              Enum.reduce(last.events, collected, fn e, acc ->
                if e.sequence > cursor, do: Map.put(acc, e.id, e), else: acc
              end)

            case client_request(conn, Map.values(collected), targets) do
              nil -> {"worker_exit_#{code}", collected, nil}
              request -> {"recovered", collected, request.request_id}
            end
        after
          500 -> observe(port, log, conn, cursor, targets, budget, collected)
        end
    end
  end

  defp client_request(conn, events, targets) do
    Enum.find(events, fn e ->
      if e.type == "request" and e.actor_id == "sales" and e.body["arbiter"]["kind"] == "human" do
        {:ok, request} = Store.view(conn, "request", e.request_id)
        MapSet.subset?(targets, MapSet.new(leaves(request), & &1.id))
      else
        false
      end
    end)
  end

  defp records(conn) do
    {:ok, closed} = Store.recent_runs(conn, 64)
    {:ok, open} = Store.open_runs(conn)

    opened =
      Enum.map(open, fn run ->
        {:ok, events} = Store.replay(conn, {:run, run.id})
        Map.put(run, :events, events)
      end)

    runs = closed ++ opened

    events =
      runs
      |> Enum.flat_map(& &1.events)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn e ->
        Map.update!(e, :body, fn text ->
          case Jason.decode(text) do
            {:ok, value} -> value
            {:error, _} -> text
          end
        end)
      end)

    %{runs: runs, events: events}
  end

  defp stop_worker(project) do
    case File.read(Path.join(project, "worker.pid")) do
      {:ok, text} ->
        pid = String.trim(text)

        case File.read("/proc/#{pid}/cmdline") do
          {:ok, command} ->
            if String.contains?(command, project) do
              stat =
                File.read!("/proc/#{pid}/stat")
                |> String.split(") ", parts: 2)
                |> List.last()
                |> String.split()

              group = Enum.at(stat, 2)
              System.cmd("kill", ["-TERM", "--", "-#{group}"], stderr_to_stdout: true)
              wait_stopped(pid, 100)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp wait_stopped(_pid, 0), do: raise("worker did not stop after SIGTERM")

  defp wait_stopped(pid, remaining) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        if String.contains?(stat, ") Z "),
          do: :ok,
          else:
            (
              Process.sleep(100)
              wait_stopped(pid, remaining - 1)
            )

      _ ->
        :ok
    end
  end

  defp leaves(%{origins: origins} = request) when map_size(origins) == 0, do: [request]
  defp leaves(%{origins: origins}), do: origins |> Map.values() |> Enum.flat_map(&leaves/1)

  defp erase(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        File.chmod!(path, 0o700)
        Enum.each(File.ls!(path), &erase(Path.join(path, &1)))
        File.rmdir!(path)

      {:ok, _} ->
        File.rm!(path)

      {:error, :enoent} ->
        :ok
    end
  end

  defp write_json(path, data), do: File.write!(path, Jason.encode!(data, pretty: true))
end
