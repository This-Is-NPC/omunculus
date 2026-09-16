defmodule Omunculus.Tool.Catalog do
  @moduledoc """
  Discovers tool/hook folders on disk and MCP servers' tools, per spec
  §8.4 and §8.7. Folder roots are merged builtin, user, then project root;
  MCP servers are merged between the user root and the project root, so a
  project folder wins over an MCP name and an MCP name wins over the
  builtin, the most specific always winning on a shared `name`. Also
  derives the group map of spec §9.5 from the manifests' own `groups`
  field.
  """

  require Logger

  alias Omunculus.Mcp
  alias Omunculus.Tool.Manifest

  @spec roots(String.t()) :: [Path.t()]
  def roots(project_dir) do
    [
      Application.app_dir(:omunculus, "priv/tools"),
      Path.expand("~/.omunculus/tools"),
      Path.join(project_dir, "tools")
    ]
  end

  @spec discover([Path.t()], [Omunculus.Config.mcp_server()]) :: %{String.t() => Manifest.t()}
  def discover(roots, servers \\ [])

  def discover(roots, servers) do
    [project_root | earlier_roots] = Enum.reverse(roots)

    earlier_roots
    |> Enum.reverse()
    |> discover_folders()
    |> discover_mcp(servers)
    |> discover_folders([project_root])
  end

  defp discover_folders(acc \\ %{}, roots) do
    Enum.reduce(roots, acc, fn root, acc ->
      if File.dir?(root) do
        root |> subfolders() |> Enum.reduce(acc, &load_into(&2, &1))
      else
        acc
      end
    end)
  end

  defp discover_mcp(acc, servers) do
    Enum.reduce(servers, acc, fn server, acc ->
      case Mcp.list_tools(server) do
        {:ok, tools} -> Enum.reduce(tools, acc, &Map.put(&2, &1.name, to_manifest(&1, server)))
        {:error, reason} -> log_skip_mcp(server.name, reason) && acc
      end
    end)
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
