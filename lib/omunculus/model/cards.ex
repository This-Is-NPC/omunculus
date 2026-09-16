defmodule Omunculus.Model.Cards do
  @moduledoc """
  Reads the names a model can see under an assembled prompt's `## Tools`
  section (spec §8.6), one per `Omunculus.Tool.Manifest.card/1` line.
  """

  @spec names(String.t()) :: MapSet.t(String.t())
  def names(assembled) do
    ~r/^- ([^\s:]+):/m
    |> Regex.scan(assembled)
    |> MapSet.new(fn [_line, name] -> name end)
  end
end
