defmodule Omunculus.Model.Fake do
  @moduledoc """
  A model that never calls a tool: it records and returns
  `fake model: ` followed by the first non-empty line of its prompt.
  """

  @spec new(map) ::
          (Omunculus.Prompt.t(),
           [map],
           (String.t(), map -> {:ok, String.t()} | {:error, term}),
           (map -> :ok | {:error, term}),
           (String.t() -> :ok),
           term ->
             {:ok, String.t()})
  def new(_spec) do
    fn prompt, _tools, _call, record, _delta, _execution ->
      first_line =
        prompt
        |> Omunculus.Prompt.text()
        |> String.split("\n")
        |> Enum.find("", &(&1 != ""))

      text = "fake model: " <> first_line
      :ok = record.(text)
      {:ok, text}
    end
  end
end
