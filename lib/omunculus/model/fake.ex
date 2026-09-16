defmodule Omunculus.Model.Fake do
  @moduledoc """
  The model of stage 1: never calls a tool, echoes back the first
  non-empty line of the assembled prompt it was given.
  """

  @spec complete(String.t(), [map], (String.t(), map -> {:ok, String.t()} | {:error, term})) ::
          {:ok, String.t()}
  def complete(assembled, _tools, _call) do
    first_line =
      assembled
      |> String.split("\n")
      |> Enum.find("", &(&1 != ""))

    {:ok, "fake model: " <> first_line}
  end
end
