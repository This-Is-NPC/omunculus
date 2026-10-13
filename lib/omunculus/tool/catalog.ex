defmodule Omunculus.Tool.Catalog do
  @moduledoc """
  Discovers tool/hook folders, Agent Skills and MCP servers' tools, per
  spec §8.4 and §8.7. Discovery walks `tools.paths` in order, then the
  skills of `tools.skills` (`Omunculus.Skills`, named `skill.<name>`), then
  `[[mcp.servers]]`, then inline `[tools.<name>]` tables; the last
  declaration of a `name` wins. Also derives the group map of spec §9.5 from the manifests'
  own `groups` field. A tool named as a group is refused, so that a name
  in a ceiling list is either a tool or a group.
  """

  require Logger

  alias Omunculus.{Mcp, Secrets, Skills}
  alias Omunculus.Tool.Manifest

  alias Omunculus.Execution.Policy

  @type tools :: Omunculus.Config.tools()

  @spec unconfigured() :: %{String.t() => Manifest.t()}
  def unconfigured do
    case Application.get_env(:omunculus, :package_tools) do
      path when is_binary(path) and path != "" ->
        discover(%{paths: [path], inline: %{}, skills: []}, [], nil)

      _missing ->
        %{}
    end
  end

  @doc """
  The catalog: the tool folders under `paths`, the tools each MCP server
  lists, then the inline tools. A server is asked only with an execution
  `policy`, and with the values `secrets` resolves for it: a fun from the
  server to `{:ok, values}` or `{:error, reason}`; without one, a server
  that binds secrets is skipped.
  """
  @spec discover(tools, [Omunculus.Config.mcp_server()], Policy.t() | nil, fun | nil) ::
          %{String.t() => Manifest.t()}
  def discover(tools, servers \\ [], policy \\ nil, secrets \\ nil)

  def discover(%{paths: paths, inline: inline, skills: skills}, servers, policy, secrets)
      when is_list(paths) and is_map(inline) do
    %{}
    |> discover_folders(paths)
    |> Map.merge(Skills.discover(skills))
    |> discover_mcp(servers, policy, secrets)
    |> Map.merge(inline)
    |> refuse_group_names()
  end

  defp refuse_group_names(catalog) do
    catalog
    |> groups()
    |> Enum.filter(fn {group, _members} -> Map.has_key?(catalog, group) end)
    |> Enum.reduce(catalog, fn {group, members}, acc ->
      Logger.warning(
        "skipping tool #{group}: its name is the group of #{Enum.join(members, ", ")}; " <>
          "rename the tool or the group"
      )

      Map.delete(acc, group)
    end)
  end

  defp discover_folders(acc, roots) do
    Enum.reduce(roots, acc, fn root, acc ->
      if File.dir?(root) do
        root |> subfolders() |> Enum.reduce(acc, &load_into(&2, &1, root))
      else
        acc
      end
    end)
  end

  defp discover_mcp(acc, [], _policy, _secrets), do: acc

  defp discover_mcp(acc, servers, %Policy{} = policy, secrets) do
    Enum.reduce(servers, acc, fn server, acc ->
      with {:ok, values} <- server_secrets(server, secrets),
           {:ok, tools} <- listed(server, policy, values) do
        Enum.reduce(tools, acc, &Map.put(&2, &1.name, to_manifest(&1, server)))
      else
        {:error, reason} -> log_skip_mcp(server.name, reason) && acc
      end
    end)
  end

  # Outside a run there is no execution to start a server in: a call from
  # the command line sees no MCP tool, as expected.
  defp discover_mcp(acc, _servers, nil, _secrets), do: acc

  defp server_secrets(%{secrets: binding}, _secrets) when map_size(binding) == 0, do: {:ok, %{}}
  defp server_secrets(_server, nil), do: {:error, :secrets_unresolved}
  defp server_secrets(server, secrets), do: secrets.(server)

  # What fails is logged; a secret the server printed is not.
  defp listed(server, policy, values) do
    case Mcp.list_tools(server, policy, values) do
      {:ok, tools} -> {:ok, tools}
      {:error, reason} -> {:error, Secrets.mask(reason, values)}
    end
  end

  defp to_manifest(tool, server) do
    %Manifest{
      name: tool.name,
      kind: "tool",
      triggers: ["model"],
      description: tool.description,
      parameters: tool.parameters,
      tags: ["mcp", server.name],
      groups: [],
      command: nil,
      module: nil,
      dir: nil,
      secrets: Map.keys(server.secrets),
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

  @doc """
  The folders a run's commands read the tools from: each folder of
  `[tools] paths` a tool was found in, whole, and the folder of a tool
  found elsewhere (a skill, an inline tool).
  """
  @spec implementation_roots(%{String.t() => Manifest.t()}) :: [Path.t()]
  def implementation_roots(catalog) do
    catalog
    |> Map.values()
    |> Enum.flat_map(fn
      %Manifest{root: root} when is_binary(root) -> [root]
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

  defp load_into(acc, dir, root) do
    case manifest_path(dir) do
      {:ok, path} ->
        case Manifest.load(path) do
          {:ok, manifest} -> Map.put(acc, manifest.name, %{manifest | root: root})
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
