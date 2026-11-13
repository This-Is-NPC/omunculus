defmodule Omunculus.Process.Conformance do
  @moduledoc """
  Each work's stage sequence against the workflow the config declares for
  it. A work follows it when it enters the stages in order, each once, and,
  once it ended, ended in the last one. Otherwise it deviates, by kind:

  - `skipped stage`: it entered a stage past the next one;
  - `repeated stage`: it entered the stage it was already in;
  - `out of order`: it went back to an earlier stage, or to one the
    workflow does not declare;
  - `ended outside its last stage`: it is done or cancelled, not in the
    last stage.

  Works of no workflow, or of one the config lacks, are not checked.
  """

  @kinds ["skipped stage", "repeated stage", "out of order", "ended outside its last stage"]

  @type result :: %{
          checked: non_neg_integer,
          followed: non_neg_integer,
          deviations: %{String.t() => [%{work: map, detail: String.t()}]}
        }

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec check([map], %{String.t() => [map]}) :: result
  def check(works, workflows) do
    found =
      for work <- works,
          steps = workflows[work.workflow],
          work.stages != [],
          do: {work, deviations(work, Enum.map(steps, & &1.name))}

    %{
      checked: length(found),
      followed: Enum.count(found, fn {_work, list} -> list == [] end),
      deviations:
        Map.new(@kinds, fn kind ->
          {kind,
           for({work, list} <- found, {^kind, detail} <- list, do: %{work: work, detail: detail})}
        end)
    }
  end

  defp deviations(work, declared) do
    indexes = Enum.map(work.stages, fn stage -> Enum.find_index(declared, &(&1 == stage)) end)

    moves =
      indexes
      |> Enum.zip(work.stages)
      |> Enum.reduce({-1, []}, fn {index, stage}, {previous, found} ->
        {if(index, do: index, else: previous), found ++ move(index, previous, stage, declared)}
      end)
      |> elem(1)

    last = List.last(indexes)

    ending =
      if work.state in ["done", "cancelled"] and last != length(declared) - 1,
        do: [{"ended outside its last stage", "ended #{work.state} in #{List.last(work.stages)}"}],
        else: []

    moves ++ ending
  end

  defp move(nil, _previous, stage, _declared), do: [{"out of order", "#{stage} is not declared"}]

  defp move(index, previous, stage, _declared) when index == previous,
    do: [{"repeated stage", stage}]

  defp move(index, previous, stage, _declared) when index < previous,
    do: [{"out of order", "back to #{stage}"}]

  defp move(index, previous, stage, declared) when index > previous + 1,
    do: [
      {"skipped stage",
       "#{Enum.join(Enum.slice(declared, (previous + 1)..(index - 1)//1), ", ")} before #{stage}"}
    ]

  defp move(_index, _previous, _stage, _declared), do: []
end
