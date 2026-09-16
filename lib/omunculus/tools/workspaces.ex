defmodule Omunculus.Tools.Workspaces do
  @moduledoc """
  Builtin `workspaces` tool, per spec §9.4: lists every configured
  workspace as `"<name> <root>"`, one per line, marking the run's own
  with `*`. Reads the `"workspaces"` view the harness provides.
  """

  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{view: view}) do
    view
    |> Map.get("workspaces", [])
    |> Enum.map_join("\n", &line/1)
    |> Out.ok()
  end

  defp line(%{name: name, root: root, current: true}), do: "#{name} #{root} *"
  defp line(%{name: name, root: root, current: false}), do: "#{name} #{root}"
end
