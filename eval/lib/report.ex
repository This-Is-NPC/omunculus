defmodule EquivalentExchange.Report do
  @moduledoc """
  Reads a result folder and writes what it says: `summary.json` and
  `report.md`, the totals, then by configuration, by scenario and by task,
  and the findings grouped by cause with where each happened; and, against
  an earlier run, `comparison.md`: what passes now that failed, what fails
  now that passed, and how each measure moved, overall and by
  configuration. A run compares itself with the run before it in
  `eval/results`.
  """

  @measures ~w(passed false_success stopped_well asked_when_needed exercised forbidden delegated)

  @spec write(String.t()) :: map
  def write(folder) do
    summary = summarize(folder)
    File.write!(Path.join(folder, "summary.json"), Jason.encode!(summary, pretty: true))
    File.write!(Path.join(folder, "report.md"), markdown(summary))

    case previous(folder) do
      nil ->
        :ok

      before ->
        File.write!(Path.join(folder, "comparison.md"), compare(summarize(before), summary))
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
              do: score["stopped_well"]
        ),
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

  defp previous(folder) do
    root = Path.dirname(folder)
    name = Path.basename(folder)

    root
    |> File.ls!()
    |> Enum.filter(&(&1 < name and File.regular?(Path.join([root, &1, "manifest.json"]))))
    |> Enum.sort()
    |> List.last()
    |> then(&(&1 && Path.join(root, &1)))
  end

  defp markdown(summary) do
    manifest = summary.manifest

    """
    # Equivalent Exchange · #{summary.run}

    Model `#{manifest["model"]}` · commit `#{manifest["commit"]}` · #{manifest["repetitions"]} repetition(s) · #{summary.totals.executions} executions

    #{table("Totals", %{"all" => summary.totals})}
    #{table("By configuration", summary.by_configuration)}
    #{table("By scenario", summary.by_scenario)}
    #{table("By task", summary.by_task)}
    ## Findings by cause

    #{findings(summary.findings)}
    """
  end

  defp table(title, rows) do
    header =
      "| | passed | false success | stopped well | asked when needed | exercised | forbidden grants | delegated | retries | tokens | cost | seconds |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n"

    lines =
      rows
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, t} ->
        "| #{name} | #{pct(t.passed)} | #{t.false_success} | #{pct(t.stopped_well)} | #{pct(t.asked_when_needed)} | #{pct(t.exercised)} | #{t.forbidden} | #{pct(t.delegated)} | #{t.retries} | #{t.tokens} | #{t.cost} | #{t.seconds} |"
      end)

    "## #{title}\n\n" <> header <> lines <> "\n"
  end

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

    Model `#{before.manifest["model"]}` → `#{now.manifest["model"]}` · commit `#{before.manifest["commit"]}` → `#{now.manifest["commit"]}`

    ## Better

    #{if better == [], do: "None.", else: Enum.join(better, "\n")}

    ## Worse

    #{if worse == [], do: "None.", else: Enum.join(worse, "\n")}

    ## In one run only

    #{if only == [], do: "None.", else: Enum.join(only, "\n")}

    #{delta_table("Overall", %{"all" => before.totals}, %{"all" => now.totals})}
    #{delta_table("By configuration", before.by_configuration, now.by_configuration)}
    """
  end

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

  @rates ~w(passed stopped_well asked_when_needed exercised delegated)

  defp delta(_column, nil, nil), do: "–"
  defp delta(column, was, is) when was == is, do: format(column, is)
  defp delta(column, was, is), do: "#{format(column, was)} → #{format(column, is)}"

  defp format(_column, nil), do: "–"
  defp format(column, value) when column in @rates, do: pct(value)
  defp format(_column, value), do: to_string(value)

  defp pct(nil), do: "–"
  defp pct(rate), do: "#{round(rate * 100)}%"
end
