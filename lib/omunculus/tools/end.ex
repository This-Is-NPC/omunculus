defmodule Omunculus.Tools.End do
  @moduledoc """
  Builtin `end` tool: emits `end`, the only action that ends the run that
  calls it. A human command has no run, so this step emits nothing.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{run_id: nil}), do: Out.ok("")

  def run(_input) do
    Out.ok("", [%{"type" => "end", "body" => %{}}])
  end
end
