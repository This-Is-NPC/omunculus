defmodule Omunculus.Tools.End do
  @moduledoc """
  Builtin `end` tool: emits `end`, the only action that ends the run that
  calls it.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(_input) do
    Out.ok("", [%{"type" => "end", "body" => %{}}])
  end
end
