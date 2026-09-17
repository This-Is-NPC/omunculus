defmodule Omunculus.Model.Fake do
  @moduledoc """
  The model of stage 1: never calls a tool, echoes back the first
  non-empty line of the assembled prompt it was given.
  """

  @spec new(map) ::
          (String.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           term ->
             {:ok, String.t()})
  def new(_spec) do
    fn assembled, _tools, _call, record, _execution ->
      first_line =
        assembled
        |> String.split("\n")
        |> Enum.find("", &(&1 != ""))

      text = "fake model: " <> first_line
      :ok = record.(text)
      {:ok, text}
    end
  end
end
