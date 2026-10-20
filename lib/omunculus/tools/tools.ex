defmodule Omunculus.Tools.Tools do
  @moduledoc """
  Builtin `tools` tool: the project's catalog, in JSON, for a client to
  list. Each entry has its `name`, `kind` (`tool`, `hook` or `skill`),
  `description`, `triggers`, `groups`, the `secrets` it declares and the
  binding the config gives them, the tools a skill's `allowed-tools`
  names (`uses`), and where it comes from: `source`
  (`folder`, `inline` or `skill`) and `dir`. MCP servers are listed apart,
  as the config declares them: their tools are known only once a run
  starts them.
  """

  alias Omunculus.Config
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Out

  @spec run(map) :: map
  def run(%{config_path: path}) when is_binary(path) do
    case Config.load(path) do
      {:ok, config} -> config |> describe() |> Jason.encode!() |> Out.ok()
      {:error, reason} -> Out.fail(inspect(reason))
    end
  end

  def run(_input), do: Out.fail("config_path required")

  defp describe(config) do
    %{
      tools:
        config.tools
        |> Catalog.discover()
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&entry(config, &1)),
      mcp:
        Enum.map(config.mcp, fn server ->
          %{name: server.name, command: server.command, secrets: server.secrets}
        end)
    }
  end

  defp entry(config, manifest) do
    %{
      name: manifest.name,
      kind: manifest.kind,
      description: manifest.description,
      triggers: manifest.triggers,
      groups: manifest.groups,
      secrets: manifest.secrets,
      uses: manifest.uses,
      binding: Map.get(config.secrets, manifest.name, %{}),
      source: source(config, manifest),
      dir: manifest.dir
    }
  end

  defp source(_config, %{kind: "skill"}), do: "skill"

  defp source(config, manifest),
    do: if(Map.has_key?(config.tools.inline, manifest.name), do: "inline", else: "folder")
end
