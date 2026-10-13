defmodule Omunculus.Tools.Continue do
  @moduledoc """
  Builtin `continue` tool: emits "next". Only a chain step
  (`done` chains it). Names no stage, agent or model — the workflow TOML
  decides the next step; without a workflow, or on the last stage, the
  work closes.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(_input) do
    Out.ok("", [%{"type" => "continue", "body" => %{}}])
  end
end
