defmodule Omunculus.Tools.Process do
  @moduledoc """
  Builtin `process` tool: what the project's event log says of how its
  works went, mined, not read run by run (`Omunculus.Process`). Read-only.

  - conformance of each work's stage sequence to the workflow the config
    declares: fitness, the share of the works that follow it, and the
    deviations by kind with their counts and cases;
  - the most frequent variants, the activity sequences works went through;
  - each activity's count, mean and 90th percentile duration, cost and
    refusals;
  - with `support` and `confidence`, the Declare rules the works that ended
    done keep, and how many cancelled works break each.

  `workflow` keeps one workflow's works and the works below them, and only
  their events; `last` the last conversations.
  With `bpmn` (`as-is` or `to-be`) and a `workflow`, the output is that
  workflow's BPMN 2.0 instead: mined from the log, or as the config declares
  it. A case is a work, named with its conversation and its runs.
  """

  alias Omunculus.Config
  alias Omunculus.Process.{Activities, Bpmn, Conformance, Declare, Log}
  alias Omunculus.Tools.{Args, Out}

  @shown 10

  @spec run(map) :: map
  def run(%{args: args, view: view, config_path: path}) do
    with {:ok, _last} <- Args.count_text(args, "last"),
         {:ok, rules} <- thresholds(args),
         {:ok, config} <- Config.load(path),
         {:ok, workflows} <- workflows(config, args["workflow"]) do
      log = Log.build(view["log"])

      case args["bpmn"] do
        nil -> Out.ok(report(log, args, workflows, rules))
        kind -> bpmn(kind, log, config, args["workflow"])
      end
    else
      {:error, message} when is_binary(message) -> Out.fail(message)
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  # Numbers, or from the command line their text.
  defp thresholds(args) do
    case {number(args["support"]), number(args["confidence"])} do
      {nil, nil} when not is_map_key(args, "support") and not is_map_key(args, "confidence") ->
        {:ok, nil}

      {support, confidence}
      when is_number(support) and is_number(confidence) and support >= 0 and support <= 1 and
             confidence >= 0 and confidence <= 1 ->
        {:ok, {support, confidence}}

      _other ->
        {:error, "support and confidence are numbers from 0 to 1, given together"}
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp number(_value), do: nil

  defp workflows(config, nil), do: {:ok, config.workflows}

  defp workflows(config, name) do
    case Map.fetch(config.workflows, name) do
      {:ok, steps} -> {:ok, %{name => steps}}
      :error -> {:error, "no workflow #{name} in the config"}
    end
  end

  defp bpmn(_kind, _log, _config, nil), do: Out.fail("bpmn needs a workflow")

  defp bpmn("to-be", _log, config, name),
    do: Out.ok(Bpmn.to_be(name, config.workflows[name], config.agents))

  defp bpmn("as-is", log, _config, name) do
    case Log.traces(log, name) do
      [] -> Out.fail("no work went through #{name} in the log")
      traces -> Out.ok(Bpmn.as_is(name, traces))
    end
  end

  defp bpmn(_kind, _log, _config, _name), do: Out.fail("bpmn is as-is or to-be")

  defp report(log, args, workflows, rules) do
    {works, events} = scoped(log, args["workflow"])

    [
      "#{plural(length(works))}#{scope(args)}.",
      conformance(works, workflows),
      variants(works),
      activities(events),
      declare(works, rules)
    ]
    |> Enum.join("\n\n")
  end

  # With a workflow: its works and the works below them, and their events only.
  defp scoped(log, nil), do: {log.works, log.events}

  defp scoped(log, workflow) do
    ids = below(log.works, for(work <- log.works, work.workflow == workflow, do: work.id))
    {Enum.filter(log.works, &(&1.id in ids)), Enum.filter(log.events, &(&1.case in ids))}
  end

  defp below(works, ids) do
    more = for work <- works, work.parent_id in ids, work.id not in ids, do: work.id
    if more == [], do: MapSet.new(ids), else: below(works, ids ++ more)
  end

  defp scope(args) do
    [
      args["workflow"] && " of workflow #{args["workflow"]} and the works below them",
      args["last"] && " in the last #{args["last"]} conversations"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp conformance(works, workflows) do
    result = Conformance.check(works, workflows)

    header =
      if result.checked == 0,
        do: "Conformance: no work went through a workflow the config declares.",
        else:
          "Conformance to the declared workflows: fitness #{ratio(result.followed, result.checked)} (#{result.followed} of #{result.checked} works follow them)."

    kinds =
      for kind <- Conformance.kinds(), [_ | _] = found <- [result.deviations[kind]] do
        "- #{kind}: #{plural(length(found))}\n" <>
          cases(found, fn %{work: work, detail: detail} -> case_line(work) <> " (#{detail})" end)
      end

    Enum.join([header | kinds], "\n")
  end

  defp variants(works) do
    all = Activities.variants(works)

    case all do
      [] ->
        "Variants: none."

      _ ->
        "Variants (#{length(all)}, the #{min(@shown, length(all))} most frequent; a run of one activity counts once):\n" <>
          Enum.map_join(Enum.take(all, @shown), "\n", fn %{sequence: sequence, works: list} ->
            "- #{plural(length(list))}: #{Enum.join(sequence, " > ")}\n" <>
              cases(list, &case_line/1)
          end)
    end
  end

  defp activities(events) do
    stats = Activities.stats(events)

    if stats == [] do
      "Activities: none."
    else
      "Activities (tool calls and model replies; duration is the time since the run's previous event):\n" <>
        Enum.map_join(stats, "\n", fn stat ->
          "- #{stat.activity}: #{times(stat.count)}, mean #{seconds(stat.mean)}, p90 #{seconds(stat.p90)}" <>
            if(stat.usd > 0, do: ", $#{:erlang.float_to_binary(stat.usd, decimals: 4)}", else: "") <>
            if(stat.refusals > 0, do: ", #{stat.refusals} refused", else: "")
        end)
    end
  end

  defp declare(_works, nil),
    do:
      "Rules: not mined; give support and confidence, numbers from 0 to 1, to mine them from the works that ended done."

  defp declare(works, {support, confidence}) do
    rules = Declare.mine(works, support, confidence)
    failed = Enum.count(works, &(&1.state == "cancelled"))

    if rules == [] do
      "Rules (support >= #{support}, confidence >= #{confidence}): none."
    else
      "Rules of the works that ended done (support >= #{support}, confidence >= #{confidence}; #{plural(failed)} cancelled):\n" <>
        Enum.map_join(Enum.take(rules, @shown), "\n", fn rule ->
          "- #{rule.template}(#{rule.a}, #{rule.b}): support #{round2(rule.support)}, confidence #{round2(rule.confidence)}, broken by #{length(rule.violations)} of #{failed} cancelled works\n" <>
            cases(rule.violations, &case_line/1)
        end)
    end
  end

  defp cases(list, line) do
    shown = list |> Enum.take(5) |> Enum.map_join("\n", &("    " <> line.(&1)))
    more = if length(list) > 5, do: "\n    and #{length(list) - 5} more", else: ""
    shown <> more
  end

  defp case_line(work) do
    runs = work.events |> Enum.map(& &1.run) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    "work #{work.id} (conversation #{work.conversation_id}" <>
      if(runs == [], do: ")", else: ", runs #{Enum.join(runs, ", ")})")
  end

  defp plural(1), do: "1 work"
  defp plural(count), do: "#{count} works"

  defp ratio(_count, 0), do: "n/a"
  defp ratio(count, total), do: round2(count / total)

  defp round2(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)
  defp times(1), do: "once"
  defp times(count), do: "#{count} times"

  defp seconds(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1) <> " s"
end
