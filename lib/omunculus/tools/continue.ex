defmodule Omunculus.Tools.Continue do
  @moduledoc """
  Builtin `continue` tool, per spec §3.4: emits "next". Names no stage,
  agent or model — the workflow TOML decides the next step.
  """

  @spec run(map) :: map
  def run(_input) do
    %{"ok" => true, "output" => "", "emit" => [%{"type" => "continue", "body" => %{}}]}
  end
end
