defmodule Omunculus.Tool.Catalog do
  @moduledoc """
  Discovers tool/hook folders and MCP servers' tools, per spec §8.4 and
  §8.7. Discovery walks `tools.paths` in order, then `[[mcp.servers]]`,
  then inline `[tools.<name>]` tables; the last declaration of a `name`
  wins. Also derives the group map of spec §9.5 from the manifests'
  own `groups` field.
  """

  require Logger

  alias Omunculus.Mcp
  alias Omunculus.Tool.Manifest

  alias Omunculus.Execution.Policy

  @type tools :: %{paths: [String.t()], inline: %{String.t() => Manifest.t()}}

  @spec unconfigured() :: %{String.t() => Manifest.t()}
  def unconfigured do
    case Application.get_env(:omunculus, :package_tools) do
      path when is_binary(path) and path != "" ->
        discover(%{paths: [path], inline: %{}}, [], nil)

      _missing ->
        %{}
    end
  end

  @spec discover(tools, [Omunculus.Config.mcp_server()], Policy.t() | nil) ::
          %{String.t() => Manifest.t()}
  def discover(tools, servers \\ [], policy \\ nil)

  def discover(%{paths: paths, inline: inline}, servers, policy)
      when is_list(paths) and is_map(inline) do
    %{}
    |> discover_folders(paths)
    |> discover_mcp(servers, policy)
    |> Map.merge(inline)
  end

  defp discover_folders(acc, roots) do
    Enum.reduce(roots, acc, fn root, acc ->
      if File.dir?(root) do
        root |> subfolders() |> Enum.reduce(acc, &load_into(&2, &1))
      else
        acc
      end
    end)
  end

  defp discover_mcp(acc, [], _policy), do: acc

  defp discover_mcp(acc, servers, %Policy{} = policy) do
    Enum.reduce(servers, acc, fn server, acc ->
      case Mcp.list_tools(server, policy) do
        {:ok, tools} -> Enum.reduce(tools, acc, &Map.put(&2, &1.name, to_manifest(&1, server)))
        {:error, reason} -> log_skip_mcp(server.name, reason) && acc
      end
    end)
  end

  defp discover_mcp(acc, servers, nil) do
    Enum.each(servers, &log_skip_mcp(&1.name, :execution_context_required))
    acc
  end

  defp to_manifest(tool, server) do
    %Manifest{
      name: tool.name,
      kind: "tool",
      shape: "simple",
      triggers: ["model"],
      description: tool.description,
      parameters: tool.parameters,
      tags: ["mcp", server.name],
      groups: [],
      command: nil,
      module: nil,
      dir: nil,
      mcp: server
    }
  end

  @spec with_trigger(%{String.t() => Manifest.t()}, String.t()) :: %{String.t() => Manifest.t()}
  def with_trigger(catalog, trigger) do
    catalog
    |> Enum.filter(fn {_name, manifest} -> Manifest.triggered_by?(manifest, trigger) end)
    |> Map.new()
  end

  @spec hooks_for(%{String.t() => Manifest.t()}, String.t()) :: [Manifest.t()]
  def hooks_for(catalog, event_type) do
    catalog
    |> Map.values()
    |> Enum.filter(&(event_type in &1.events))
    |> Enum.sort_by(& &1.name)
  end

  @spec groups(%{String.t() => Manifest.t()}) :: %{String.t() => [String.t()]}
  def groups(catalog) do
    catalog
    |> Map.values()
    |> Enum.flat_map(fn manifest -> Enum.map(manifest.groups, &{&1, manifest.name}) end)
    |> Enum.group_by(fn {group, _name} -> group end, fn {_group, name} -> name end)
    |> Map.new(fn {group, names} -> {group, Enum.sort(names)} end)
  end

  @spec implementation_roots(%{String.t() => Manifest.t()}) :: [Path.t()]
  def implementation_roots(catalog) do
    catalog
    |> Map.values()
    |> Enum.flat_map(fn
      %Manifest{dir: dir} when is_binary(dir) -> [dir]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp subfolders(root) do
    root
    |> File.ls!()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.dir?/1)
  end

  defp load_into(acc, dir) do
    case manifest_path(dir) do
      {:ok, path} ->
        case Manifest.load(path) do
          {:ok, manifest} -> Map.put(acc, manifest.name, manifest)
          {:error, reason} -> log_skip(path, reason) && acc
        end

      {:error, reason} ->
        log_skip(dir, reason) && acc

      :skip ->
        acc
    end
  end

  defp manifest_path(dir) do
    tool = Path.join(dir, "tool.toml")
    hook = Path.join(dir, "hook.toml")

    case {File.regular?(tool), File.regular?(hook)} do
      {true, true} -> {:error, :ambiguous}
      {true, false} -> {:ok, tool}
      {false, true} -> {:ok, hook}
      {false, false} -> :skip
    end
  end

  defp log_skip_mcp(name, reason) do
    Logger.warning("skipping MCP server #{name}: #{inspect(reason)}")
    true
  end

  defp log_skip(path, reason) do
    Logger.warning("skipping tool manifest at #{path}: #{inspect(reason)}")
    true
  end
end
