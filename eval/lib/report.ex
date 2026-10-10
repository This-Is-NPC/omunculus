defmodule EquivalentExchange.Report do
  @moduledoc """
  Reads a result folder and writes what it says: `summary.json` and
  `report.md`, the totals, then by configuration, by scenario and by task,
  and the findings grouped by cause with where each happened; and, against
  an earlier run, `comparison.md`: what passes now that failed, what fails
  now that passed, and how each measure moved, overall and by
  configuration. A run is compared with the result folder its manifest
  names under `against`, and with none when it names none.
  """

  alias EquivalentExchange.Resources

  @measures ~w(passed false_success stopped_well unbacked unreported done_unchanged asked_when_needed exercised forbidden delegated rated cache first_call_cache)

  @spec write(String.t()) :: map
  def write(folder) do
    summary = summarize(folder)
    File.write!(Path.join(folder, "summary.json"), Jason.encode!(summary, pretty: true))
    File.write!(Path.join(folder, "report.md"), markdown(summary))

    comparison = Path.join(folder, "comparison.md")

    case summary.manifest["against"] do
      nil -> File.rm(comparison)
      before -> File.write!(comparison, compare(summarize(before), summary))
    end

    summary
  end

  @doc "The comparison of two result folders, earlier first, as markdown."
  @spec compare_folders(String.t(), String.t()) :: String.t()
  def compare_folders(before, now), do: compare(summarize(before), summarize(now))

  defp executions(folder) do
    Path.join([folder, "executions", "*", "*", "*", "execution.json"])
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  defp summarize(folder) do
    manifest = folder |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    all = executions(folder)

    %{
      run: Path.basename(folder),
      manifest: manifest,
      totals: tally(all),
      by_configuration: by(all, & &1["configuration"]),
      by_scenario: by(all, & &1["scenario"]),
      by_task: by(all, &"#{&1["task"]} · #{&1["configuration"]}"),
      cache_by_agent: by_agent(all),
      resources: resources(folder, all),
      findings:
        all
        |> Enum.flat_map(fn execution ->
          for finding <- execution["score"]["findings"] do
            Map.put(
              finding,
              "where",
              "#{execution["task"]} · #{execution["configuration"]} · #{execution["repetition"]}"
            )
          end
        end)
        |> Enum.group_by(& &1["cause"])
    }
  end

  defp by(all, key),
    do: all |> Enum.group_by(key) |> Map.new(fn {name, group} -> {name, tally(group)} end)

  defp tally(group) do
    scores = Enum.map(group, & &1["score"])

    rate = fn values ->
      if values == [], do: nil, else: Float.round(Enum.count(values, & &1) / length(values), 3)
    end

    %{
      executions: length(group),
      passed: rate.(Enum.map(scores, & &1["passed"])),
      false_success: Enum.count(scores, & &1["false_success"]),
      stopped_well:
        rate.(
          for {execution, score} <- Enum.zip(group, scores),
              Enum.all?(execution["expected"], &(&1 != "done")),
              score["stopped_well"] != nil,
              do: score["stopped_well"]
        ),
      # A score from before the decider, kept by a task since removed, has none of these.
      unbacked: Enum.count(scores, &(&1["unbacked"] not in [nil, []])),
      unreported: Enum.count(scores, &(&1["unreported"] not in [nil, []])),
      done_unchanged: Enum.count(scores, &(&1["done_unchanged"] == true)),
      unsure: Enum.count(scores, &(&1["unsure"] not in [nil, []])),
      rated: mean(Enum.flat_map(scores, &Map.values(&1["rated"] || %{}))),
      cache: cache_rate(Enum.map(scores, & &1["cache"])),
      first_call_cache: cache_rate(Enum.map(scores, & &1["first_call_cache"])),
      asked_when_needed:
        rate.(
          for score <- scores, score["asked_when_needed"] != nil, do: score["asked_when_needed"]
        ),
      exercised: rate.(for score <- scores, score["exercised"] != nil, do: score["exercised"]),
      forbidden: Enum.count(scores, &(&1["forbidden_grants"] != [])),
      delegated: rate.(Enum.map(scores, & &1["delegated"])),
      retries: Enum.sum(Enum.map(scores, & &1["retries"])),
      tokens: Enum.sum(Enum.map(scores, & &1["tokens"])),
      cost: Float.round(Enum.sum(Enum.map(scores, &(&1["cost"] * 1.0))), 6),
      seconds: Float.round(Enum.sum(Enum.map(scores, & &1["duration_ms"])) / 1000, 1)
    }
  end

  # The share of the prompt tokens served from the cache.
  defp cache_rate(caches) do
    case Enum.reject(caches, &is_nil/1) do
      [] ->
        nil

      known ->
        prompt = Enum.sum(Enum.map(known, & &1["prompt_tokens"]))
        cached = Enum.sum(Enum.map(known, & &1["cached_tokens"]))
        if prompt == 0, do: nil, else: Float.round(cached / prompt, 3)
    end
  end

  defp by_agent(all) do
    all
    |> Enum.flat_map(&Map.to_list(&1["score"]["cache_by_agent"] || %{}))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {agent, caches} -> {agent, cache_rate(caches)} end)
  end

  # What the run took from the machine, overall and by agent, when it was
  # sampled with the sandboxed processes' CPU; each agent also with its
  # runs and how long they were open. A run sampled before that reads as
  # not sampled.
  defp resources(folder, all) do
    path = Path.join(folder, "resources.json")
    samples = if File.regular?(path), do: path |> File.read!() |> Jason.decode!()

    if samples && Enum.all?(samples["beam"], &Map.has_key?(&1, "children_cpu_percent")) do
      hardware = Resources.by_agent(samples, all)

      runs =
        for execution <- all, run <- execution["runs"], run["finished_at"], reduce: %{} do
          acc ->
            seconds = seconds_between(run["started_at"], run["finished_at"])
            Map.update(acc, run["agent"], {1, seconds}, fn {n, s} -> {n + 1, s + seconds} end)
        end

      by_agent =
        Map.new(Enum.uniq(Map.keys(runs) ++ Map.keys(hardware)), fn agent ->
          {n, seconds} = Map.get(runs, agent, {0, 0.0})

          {agent,
           Map.merge(Map.get(hardware, agent, %{}), %{
             "runs" => n,
             "run_s" => Float.round(seconds, 1)
           })}
        end)

      %{overall: Resources.overall(samples, all), by_agent: by_agent}
    end
  end

  defp seconds_between(from, to) do
    {:ok, a, _} = DateTime.from_iso8601(from)
    {:ok, b, _} = DateTime.from_iso8601(to)
    DateTime.diff(b, a, :millisecond) / 1000
  end

  defp hardware(nil), do: "Not sampled.\n"

  defp hardware(%{overall: overall, by_agent: by_agent}) do
    head =
      "The BEAM and the sandboxed processes together: CPU median #{whole(overall["cpu_percent_median"])}% and peak #{whole(overall["cpu_percent_peak"])}% of one core; memory peak #{whole(overall["rss_mb_peak"])} MB.\n\n" <>
        "Most runs open at once: #{overall["runs_open_peak"]}, at #{overall["runs_open_peak_at"]}, taking #{whole(overall["runs_open_peak_cpu_percent"])}% of one core and #{whole(overall["runs_open_peak_rss_mb"])} MB.\n\n" <>
        "The BEAM's CPU is shared among the runs open at each moment, so its split is an estimate; sandboxed processes count to the run that started them.\n\n" <>
        "| agent | runs | run time s | BEAM CPU s (est.) | sandbox CPU s | sandbox peak MB |\n|---|---|---|---|---|---|\n"

    rows =
      by_agent
      |> Enum.sort()
      |> Enum.map_join("\n", fn {agent, h} ->
        "| #{agent} | #{h["runs"]} | #{h["run_s"]} | #{h["beam_cpu_s"] || 0} | #{h["sandbox_cpu_s"] || 0} | #{h["sandbox_peak_rss_mb"] || 0} |"
      end)

    head <> rows <> "\n"
  end

  defp code_mode(%{"code_mode" => true}), do: " in code mode"
  defp code_mode(_manifest), do: ""

  # A measure of the machine as a whole number: 1300.0 reads 1300, not 1.3e3.
  defp whole(nil), do: "–"
  defp whole(value), do: value |> round() |> Integer.to_string()

  defp mean(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      known -> Float.round(Enum.sum(known) / length(known), 2)
    end
  end

  defp markdown(summary) do
    manifest = summary.manifest

    """
    # Equivalent Exchange · #{summary.run}

    Model `#{manifest["model"]}`#{code_mode(manifest)} · commit `#{manifest["commit"]}` · #{manifest["repetitions"]} repetition(s) · #{summary.totals.executions} executions · #{trust(manifest["judge"])}

    #{table("Totals", %{"all" => summary.totals})}
    #{table("By configuration", summary.by_configuration)}
    #{table("By scenario", summary.by_scenario)}
    #{table("By task", summary.by_task)}
    ## Cache by agent

    The share of each agent's prompt tokens the provider served from its cache.

    #{summary.cache_by_agent |> Enum.sort() |> Enum.map_join("\n", fn {agent, rate} -> "- #{agent}: #{pct(rate)}" end)}

    ## Hardware by agent

    #{hardware(summary.resources)}
    ## Findings by cause

    #{findings(summary.findings)}
    """
  end

  defp table(title, rows) do
    header =
      "| | passed | false success | stopped well | unbacked claims | unreported changes | done, nothing changed | asked when needed | exercised | forbidden grants | delegated | rated | judge unsure | retries | tokens | cache | cache, 1st call | cost | seconds |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"

    lines =
      rows
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, t} ->
        "| #{name} | #{pct(t.passed)} | #{t.false_success} | #{pct(t.stopped_well)} | #{t.unbacked} | #{t.unreported} | #{t.done_unchanged} | #{pct(t.asked_when_needed)} | #{pct(t.exercised)} | #{t.forbidden} | #{pct(t.delegated)} | #{t.rated || "–"} | #{t.unsure} | #{t.retries} | #{t.tokens} | #{pct(t.cache)} | #{pct(t.first_call_cache)} | #{t.cost} | #{t.seconds} |"
      end)

    "## #{title}\n\n" <> header <> lines <> "\n"
  end

  # How far the decider was trusted on the hand-written reports.
  defp trust(%{"right" => right, "asked" => asked}),
    do: "judge right on #{right} of #{asked} hand-written answers"

  defp trust(nil), do: "no judge"

  defp findings(by_cause) when map_size(by_cause) == 0, do: "None.\n"

  defp findings(by_cause) do
    by_cause
    |> Enum.sort_by(fn {_cause, list} -> -length(list) end)
    |> Enum.map_join("\n", fn {cause, list} ->
      reasons =
        list
        |> Enum.group_by(& &1["reason"])
        |> Enum.sort_by(fn {_reason, hits} -> -length(hits) end)
        |> Enum.map_join("\n", fn {reason, hits} ->
          "- #{length(hits)}× #{reason}\n  #{hits |> Enum.map(& &1["where"]) |> Enum.take(6) |> Enum.join("; ")}"
        end)

      "### #{cause} (#{length(list)})\n\n" <> reasons <> "\n"
    end)
  end

  defp compare(before, now) do
    keys = Map.keys(before.by_task) ++ Map.keys(now.by_task)

    changes =
      for key <- Enum.uniq(keys) |> Enum.sort(),
          {was, is} =
            {get_in(before.by_task, [key, :passed]), get_in(now.by_task, [key, :passed])},
          was != is,
          do: {key, was, is}

    both = for {_key, was, is} = change <- changes, was != nil and is != nil, do: change
    better = for {key, was, is} <- both, is > was, do: "- #{key}: #{pct(was)} → #{pct(is)}"
    worse = for {key, was, is} <- both, is < was, do: "- #{key}: #{pct(was)} → #{pct(is)}"

    only =
      for {key, was, is} <- changes,
          was == nil or is == nil,
          do: "- #{key}: only #{if is == nil, do: "before", else: "now"}"

    """
    # #{now.run} against #{before.run}

    Model `#{before.manifest["model"]}`#{code_mode(before.manifest)} → `#{now.manifest["model"]}`#{code_mode(now.manifest)} · commit `#{before.manifest["commit"]}` → `#{now.manifest["commit"]}`

    ## Better

    #{if better == [], do: "None.", else: Enum.join(better, "\n")}

    ## Worse

    #{if worse == [], do: "None.", else: Enum.join(worse, "\n")}

    ## In one run only

    #{if only == [], do: "None.", else: Enum.join(only, "\n")}

    #{delta_table("Overall", %{"all" => before.totals}, %{"all" => now.totals})}
    #{delta_table("By configuration", before.by_configuration, now.by_configuration)}
    ## Hardware

    #{hardware_delta(before.resources, now.resources)}
    """
  end

  defp hardware_delta(%{overall: was}, %{overall: is}) do
    Enum.map_join(
      [
        {"CPU median %", "cpu_percent_median"},
        {"CPU peak %", "cpu_percent_peak"},
        {"runs open at once", "runs_open_peak"},
        {"memory peak MB", "rss_mb_peak"}
      ],
      "\n",
      fn {label, key} -> "- #{label}: #{whole(was[key])} → #{whole(is[key])}" end
    )
  end

  defp hardware_delta(_before, _now), do: "Not sampled in both."

  defp delta_table(title, before, now) do
    columns = @measures ++ ~w(tokens cost seconds)

    header =
      "| | " <>
        Enum.join(columns, " | ") <>
        " |\n|---|" <> String.duplicate("---|", length(columns)) <> "\n"

    lines =
      for name <- Enum.uniq(Map.keys(before) ++ Map.keys(now)) |> Enum.sort() do
        cells =
          Enum.map(columns, fn column ->
            key = String.to_existing_atom(column)
            delta(column, get_in(before, [name, key]), get_in(now, [name, key]))
          end)

        "| #{name} | " <> Enum.join(cells, " | ") <> " |"
      end

    "## #{title}\n\n" <> header <> Enum.join(lines, "\n") <> "\n"
  end

  @rates ~w(passed stopped_well asked_when_needed exercised delegated cache first_call_cache)

  defp delta(_column, nil, nil), do: "–"
  defp delta(column, was, is) when was == is, do: format(column, is)
  defp delta(column, was, is), do: "#{format(column, was)} → #{format(column, is)}"

  defp format(_column, nil), do: "–"
  defp format(column, value) when column in @rates, do: pct(value)
  defp format(_column, value), do: to_string(value)

  defp pct(nil), do: "–"
  defp pct(rate), do: "#{round(rate * 100)}%"
end
