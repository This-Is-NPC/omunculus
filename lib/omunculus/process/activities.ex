defmodule Omunculus.Process.Activities do
  @moduledoc """
  What the log says of its activities: for each tool and for the model's
  replies, how often it happened, how long it took (mean and 90th
  percentile, nearest rank), what it cost and how often it was refused; and
  the variants, the activity sequences works went through, a run of one
  activity folded to one, most frequent first.
  """

  @spec stats([map]) :: [map]
  def stats(events) do
    events
    |> Enum.filter(&(&1.kind in [:call, :reply]))
    |> Enum.group_by(& &1.activity)
    |> Enum.map(fn {activity, list} ->
      durations = list |> Enum.map(& &1.attrs["duration"]) |> Enum.sort()

      %{
        activity: activity,
        count: length(list),
        mean: Enum.sum(durations) / length(durations),
        p90: Enum.at(durations, ceil(0.9 * length(durations)) - 1),
        usd: list |> Enum.map(&Map.get(&1.attrs, "usd", 0.0)) |> Enum.sum(),
        refusals: Enum.count(list, &(&1.attrs["ok"] == false))
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.activity})
  end

  @spec variants([map]) :: [%{sequence: [String.t()], works: [map]}]
  def variants(works) do
    works
    |> Enum.map(fn work -> {work, folded(work.events)} end)
    |> Enum.reject(fn {_work, sequence} -> sequence == [] end)
    |> Enum.group_by(fn {_work, sequence} -> sequence end, fn {work, _sequence} -> work end)
    |> Enum.map(fn {sequence, works} -> %{sequence: sequence, works: works} end)
    |> Enum.sort_by(&{-length(&1.works), &1.sequence})
  end

  defp folded(events) do
    for(%{kind: kind, activity: activity} <- events, kind in [:call, :stage, :end], do: activity)
    |> Enum.dedup()
  end
end
