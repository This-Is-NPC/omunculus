defmodule Omunculus.Tools.Done do
  @moduledoc """
  Builtin `done` tool: chains `comment` with the report and `continue`;
  its manifest's `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    case Args.present(args, "report") do
      nil ->
        Out.fail("report required")

      report ->
        Out.ok("")
        |> Map.put("chain", [
          %{"name" => "comment", "args" => %{"body" => report}},
          %{"name" => "continue", "args" => %{}}
        ])
    end
  end
end
