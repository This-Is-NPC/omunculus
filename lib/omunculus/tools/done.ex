defmodule Omunculus.Tools.Done do
  @moduledoc """
  Builtin `done` tool: chains `comment` with the report and `continue`;
  its manifest's `then` appends `end`. A run without a work has nothing
  to close: it is told to answer instead.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{work_id: nil}), do: Out.fail(Out.no_work())

  def run(%{args: args}) do
    case Args.fetch(args, "report") do
      {:ok, report} ->
        Out.ok("")
        |> Map.put("chain", [
          %{"name" => "comment", "args" => %{"body" => report}},
          %{"name" => "continue", "args" => %{}}
        ])

      {:error, message} ->
        Out.fail(message)
    end
  end
end
