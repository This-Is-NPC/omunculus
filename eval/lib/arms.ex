defmodule EquivalentExchange.Arms do
  @moduledoc """
  The paired report of the hierarchy experiment: the same tasks run once
  as a work tree (arm A, the hierarchy) and once as a single agent with a
  long session (arm B). It reads the `execution.json` of two result
  folders and, per task, sets the arms side by side with B − A, then asks
  a sign test across tasks whether either arm is better, and says plainly
  when too few tasks differ for that to mean anything.

  A task's value in an arm is the mean over its repetitions; the sign test
  compares those means task by task, ties dropped.
  """

  # With fewer differing tasks the smallest two-sided p is above 0.05.
  @min_differing 6
  @alpha 0.05

  # {key, label, which direction is better}
  @metrics [
    {:passed, "pass rate", :higher},
    {:cost, "USD", :lower},
    {:seconds, "seconds", :lower},
    {:tokens, "tokens", :lower},
    {:human, "human requests", :lower},
    {:repeated, "repeated after handoff", :lower},
    {:recovery, "recovery (breaks + reopens)", :lower},
    {:checks, "long-horizon checks held", :higher}
  ]

  @doc "The report of arm `a` (hierarchy) against arm `b` (single agent), two result folders."
  @spec report(String.t(), String.t()) :: String.t()
  def report(a, b), do: render(load(a), load(b), a, b)

  @doc "Every execution of a result folder, by task."
  @spec load(String.t()) :: %{String.t() => [map]}
  def load(folder) do
    Path.join([folder, "executions", "*", "*", "*", "execution.json"])
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.group_by(& &1["task"])
  end

  @doc "Per-task means of every metric for each arm, over the tasks both ran."
  @spec rows(%{String.t() => [map]}, %{String.t() => [map]}) :: [map]
  def rows(a, b) do
    for task <- a |> Map.keys() |> Enum.filter(&Map.has_key?(b, &1)) |> Enum.sort() do
      %{
        task: task,
        runs: {length(a[task]), length(b[task])},
        capped: {capped(a[task]), capped(b[task])},
        metrics:
          Map.new(@metrics, fn {key, _label, _better} ->
            {key, {mean(a[task], key), mean(b[task], key)}}
          end)
      }
    end
  end

  defp capped(executions), do: Enum.count(executions, &(&1["outcome"] == "budget"))

  @doc """
  The sign test of one metric over `rows`: on how many tasks B did better,
  A did better, they tied, and the exact two-sided p of the differing ones.
  """
  @spec sign([map], atom, :higher | :lower) :: map
  def sign(rows, key, better) do
    pairs = for %{metrics: %{^key => {x, y}}} <- rows, x != nil and y != nil, do: {x, y}
    gain = fn {x, y} -> if better == :higher, do: y - x, else: x - y end
    b = Enum.count(pairs, &(gain.(&1) > 0))
    a = Enum.count(pairs, &(gain.(&1) < 0))
    %{b: b, a: a, ties: length(pairs) - a - b, p: if(a + b > 0, do: p_value(a, b))}
  end

  @doc "The exact two-sided binomial p (success 0.5) of `a` against `b` wins."
  @spec p_value(non_neg_integer, non_neg_integer) :: float
  def p_value(a, b) do
    n = a + b
    tail = Enum.sum(for i <- 0..min(a, b), do: choose(n, i))
    min(1.0, 2 * tail / Integer.pow(2, n))
  end

  defp choose(n, k), do: Enum.reduce(1..k//1, 1, fn i, acc -> div(acc * (n - i + 1), i) end)

  @doc "What a sign test result allows concluding."
  @spec verdict(map) :: String.t()
  def verdict(%{a: 0, b: 0}), do: "no task differs"

  def verdict(%{a: a, b: b}) when a + b < @min_differing,
    do:
      "too few tasks differ (#{a + b}; #{@min_differing} are needed to reach p < #{@alpha}): no conclusion"

  def verdict(%{a: a, b: b, p: p}) when p < @alpha,
    do: "#{if b > a, do: "single agent", else: "hierarchy"} better (p = #{round(p, 3)})"

  def verdict(%{p: p}), do: "no significant difference (p = #{round(p, 3)})"

  # One execution's value of a metric; nil when it was not recorded.
  defp value(:passed, %{"score" => %{"passed" => passed}}) when is_boolean(passed),
    do: if(passed, do: 1.0, else: 0.0)

  defp value(:cost, %{"usage" => %{"cost" => cost}}), do: cost
  defp value(:seconds, %{"duration_ms" => ms}) when is_number(ms), do: ms / 1000

  defp value(:tokens, %{"score" => %{"tokens" => tokens}}), do: tokens

  defp value(:human, %{"score" => %{"human_requests" => requests}}), do: requests

  defp value(:repeated, %{"score" => %{"repeated_after_handoff" => repeated}}), do: repeated

  # The work the system had to redo: stops reported and works sent back.
  defp value(:recovery, %{"score" => %{"breaks" => breaks, "reopened" => reopened}}),
    do: (breaks || 0) + (reopened || 0)

  defp value(:checks, %{"score" => %{"checks_held" => held, "checks" => checks}})
       when map_size(checks) > 0,
       do: held

  defp value(_key, _execution), do: nil

  # The mean over the executions that recorded it; nil when none did.
  defp mean(executions, key), do: executions |> Enum.map(&value(key, &1)) |> average()

  defp average(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      kept -> Enum.sum(kept) / length(kept)
    end
  end

  defp render(a, b, a_folder, b_folder) do
    rows = rows(a, b)
    only = Enum.uniq(Map.keys(a) ++ Map.keys(b)) -- Enum.map(rows, & &1.task)
    reps = rows |> Enum.flat_map(&Tuple.to_list(&1.runs)) |> Enum.min(fn -> 0 end)

    [
      "# Hierarchy against a single agent\n",
      "- A, the hierarchy: `#{a_folder}`\n- B, the single agent with a long session: `#{b_folder}`\n- tasks run in both arms: #{length(rows)}; fewest repetitions of a task in an arm: #{reps}\n",
      caveats(rows, only, reps),
      "## Across tasks\n",
      "Each task counts once, as the mean of its repetitions. A sign test asks whether one arm beats the other on more tasks than chance allows; ties are dropped.\n",
      summary_table(rows),
      "\n## Per task\n",
      "Each cell is A / B / B − A. A dash is a metric no execution recorded.\n",
      task_table(rows)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp caveats(rows, only, reps) do
    capped = Enum.sum(for %{capped: {x, y}} <- rows, do: x + y)

    [
      if(length(rows) < @min_differing,
        do:
          "**Too small to conclude anything:** #{length(rows)} paired tasks cannot reach p < #{@alpha} in a sign test (#{@min_differing} that differ are needed). Read the tables as a pilot, not a result.\n"
      ),
      if(reps < 3,
        do:
          "**Few repetitions:** with #{reps} per arm, a task's value is one or two draws of a stochastic run; a difference may be noise.\n"
      ),
      if(capped > 0,
        do:
          "**#{capped} execution(s) stopped at the USD cap.** Their cost and time are cut short and they do not pass.\n"
      ),
      if(only != [], do: "Left out, run in one arm only: #{Enum.join(only, ", ")}.\n")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp summary_table(rows) do
    head =
      "| metric | A mean | B mean | tasks B better | tasks A better | ties | verdict |\n|---|---|---|---|---|---|---|"

    lines =
      for {key, label, better} <- @metrics do
        sign = sign(rows, key, better)
        {xs, ys} = rows |> Enum.map(& &1.metrics[key]) |> Enum.unzip()

        "| #{label} | #{show(average(xs))} | #{show(average(ys))} | #{sign.b} | #{sign.a} | #{sign.ties} | #{verdict(sign)} |"
      end

    Enum.join([head | lines], "\n")
  end

  defp task_table(rows) do
    labels = Enum.map_join(@metrics, " | ", &elem(&1, 1))

    head =
      "| task | runs A/B | #{labels} |\n|---|---|#{String.duplicate("---|", length(@metrics))}"

    lines =
      for %{runs: {x, y}} = row <- rows do
        cells =
          for {key, _label, _better} <- @metrics do
            {a, b} = row.metrics[key]
            "#{show(a)} / #{show(b)} / #{difference(a, b)}"
          end

        "| #{row.task} | #{x}/#{y} | #{Enum.join(cells, " | ")} |"
      end

    Enum.join([head | lines], "\n")
  end

  defp difference(a, b) when is_number(a) and is_number(b), do: show(b - a, true)
  defp difference(_a, _b), do: "–"

  defp show(value, signed \\ false)
  defp show(nil, _signed), do: "–"

  defp show(value, signed) do
    text = value |> round(3) |> to_string()
    if signed and value > 0, do: "+" <> text, else: text
  end

  defp round(value, digits), do: Float.round(value * 1.0, digits)
end
