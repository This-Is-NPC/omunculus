defmodule Omunculus.Process.Declare do
  @moduledoc """
  Declare rules between activities, mined from the works that ended done
  and checked against the works that were cancelled. A work is the
  sequence of its tool calls and stage entries.

  - `response(a, b)`: once `a` happens, `b` happens after it. Activated by
    `a`; it holds when `b` follows the last `a`.
  - `precedence(a, b)`: `b` happens only after `a`. Activated by `b`; it
    holds when `a` comes before the first `b`.

  A rule's `support` is the share of the done works that activate and
  satisfy it; its `confidence`, the share of the done works that activate
  it that satisfy it. A rule is kept when both reach the thresholds given.
  The cancelled works that activate it and break it are its violations: a
  rule that the done works keep and the failed ones break is the mark of a
  step a gate could enforce.
  """

  @kinds [response: "response", precedence: "precedence"]

  @type rule :: %{
          template: String.t(),
          a: String.t(),
          b: String.t(),
          support: float,
          confidence: float,
          violations: [map]
        }

  @spec mine([map], number, number) :: [rule]
  def mine(works, support, confidence) do
    done = sequences(works, "done")
    failed = sequences(works, "cancelled")

    activities =
      done |> Enum.flat_map(fn {_work, sequence} -> sequence end) |> Enum.uniq() |> Enum.sort()

    if done == [] do
      []
    else
      for {template, name} <- @kinds,
          a <- activities,
          b <- activities,
          a != b,
          {activated, satisfied} = tally(done, template, a, b),
          activated > 0,
          rule_support = satisfied / length(done),
          rule_confidence = satisfied / activated,
          rule_support >= support and rule_confidence >= confidence do
        %{
          template: name,
          a: a,
          b: b,
          support: rule_support,
          confidence: rule_confidence,
          violations:
            for({work, sequence} <- failed, violated?(sequence, template, a, b), do: work)
        }
      end
      |> Enum.sort_by(
        &{-length(&1.violations), -&1.confidence, -&1.support, &1.template, &1.a, &1.b}
      )
    end
  end

  defp sequences(works, state) do
    for work <- works,
        work.state == state,
        sequence =
          for(
            %{kind: kind, activity: activity} <- work.events,
            kind in [:call, :stage],
            do: activity
          ),
        sequence != [],
        do: {work, sequence}
  end

  defp tally(sequences, template, a, b) do
    Enum.reduce(sequences, {0, 0}, fn {_work, sequence}, {activated, satisfied} ->
      case verdict(sequence, template, a, b) do
        :idle -> {activated, satisfied}
        :holds -> {activated + 1, satisfied + 1}
        :breaks -> {activated + 1, satisfied}
      end
    end)
  end

  defp violated?(sequence, template, a, b), do: verdict(sequence, template, a, b) == :breaks

  defp verdict(sequence, :response, a, b) do
    case last(sequence, a) do
      nil -> :idle
      at -> if (last(sequence, b) || -1) > at, do: :holds, else: :breaks
    end
  end

  defp verdict(sequence, :precedence, a, b) do
    case first(sequence, b) do
      nil -> :idle
      at -> if (first(sequence, a) || at) < at, do: :holds, else: :breaks
    end
  end

  defp first(sequence, activity), do: Enum.find_index(sequence, &(&1 == activity))

  defp last(sequence, activity) do
    case first(Enum.reverse(sequence), activity) do
      nil -> nil
      from_end -> length(sequence) - 1 - from_end
    end
  end
end
