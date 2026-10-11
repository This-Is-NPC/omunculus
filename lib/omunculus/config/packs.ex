defmodule Omunculus.Config.Packs do
  @moduledoc """
  The teams a config imports with `[[packs]]`, each a table naming the
  pack's folder (`path`, relative to the config's directory), the model of
  the config each of its roles runs on (`models`), the `[auth]` provider
  of the config each provider it names stands for (`auth`) and, optionally,
  how many depths below its own the team works (`depth`): every agent and
  depth layer of the pack moves down that many.

  A pack is a folder with a `pack.toml`: `[pack]` gives its `name`, its
  `roles`, the `auth` providers its secrets name and the tools of other
  packs it `requires`, which importing it checks, and it may hold
  `[agents.<name>]`, each on one of its roles, `[workflows.<name>]`,
  `[secrets.<tool>]`, `[[mcp.servers]]` and `[policy.depth.<n>]`. Beside it,
  `tools/` and `skills/` are its tools and skills, `workspace/` the files a
  workspace of the team starts with and `environment/` what the team needs
  on the machine; the last two are not configuration.

  `expand/2` lays every pack under the config's own tables before they are
  parsed: an item of a pack is added, and an item of the config with its
  name overrides it key by key — a permanent grant written to the config, a
  model changed; two packs with an item of one name are refused. Roles
  become the models and providers the config maps them to, an MCP server's
  command is found from the pack's folder, and a pack's `tools/` and
  `skills/` come before the config's own paths, so the config's tools and
  skills win too.
  """

  @pack_keys ~w(pack agents workflows secrets mcp policy)
  @import_keys ~w(path models auth depth)

  @spec expand(map, String.t()) :: {:ok, map} | {:error, term}
  def expand(data, config_dir) do
    {packs, data} = Map.pop(data, "packs", [])

    if is_list(packs) do
      Enum.reduce_while(packs, {:ok, data, %{}}, fn entry, {:ok, data, owners} ->
        with {:ok, dir, pack} <- load(entry, config_dir),
             {:ok, name} <- name(pack),
             {:ok, pack} <- shift(name, pack, Map.get(entry, "depth", 0)),
             {:ok, pack} <- bind(name, pack, entry, dir),
             {:ok, data, owners} <- lay(name, pack, data, owners) do
          {:cont, {:ok, paths(data, dir), owners}}
        else
          {:error, reason} -> {:halt, {:error, {:packs, reason}}}
        end
      end)
      |> case do
        {:ok, data, _owners} -> {:ok, data}
        error -> error
      end
    else
      {:error, {:packs, {:invalid, :list}}}
    end
  end

  @doc "The pack in `dir`, as its `pack.toml` writes it."
  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(dir) do
    file = Path.join(dir, "pack.toml")

    with true <- File.regular?(file) || {:error, {:no_pack, dir}},
         {:ok, pack} <- Toml.decode_file(file),
         [] <- Map.keys(pack) -- @pack_keys,
         {:ok, _name} <- name(pack) do
      {:ok, pack}
    else
      [key | _] -> {:error, {:unknown_key, key}}
      {:error, _reason} = error -> error
    end
  end

  defp load(%{"path" => path} = entry, config_dir) when is_binary(path) and path != "" do
    dir = Path.expand(path, config_dir)

    case Map.keys(entry) -- @import_keys do
      [] -> with {:ok, pack} <- read(dir), do: {:ok, dir, pack}
      [key | _] -> {:error, {:unknown_key, key}}
    end
  end

  defp load(_entry, _config_dir), do: {:error, {:invalid, :path}}

  defp name(%{"pack" => %{"name" => name}}) when is_binary(name) and name != "", do: {:ok, name}
  defp name(_pack), do: {:error, {:invalid, :name}}

  # The team below its own depths: each agent's depth and each depth layer.
  defp shift(_name, pack, 0), do: {:ok, pack}

  defp shift(name, pack, by) when is_integer(by) and by > 0 do
    agents =
      Map.new(Map.get(pack, "agents", %{}), fn {agent, table} ->
        {agent, Map.update(table, "depth", nil, &(is_integer(&1) && &1 + by))}
      end)

    depths =
      Enum.reduce_while(get_in(pack, ["policy", "depth"]) || %{}, {:ok, %{}}, fn {n, layer},
                                                                                 {:ok, acc} ->
        case Integer.parse(n) do
          {depth, ""} -> {:cont, {:ok, Map.put(acc, Integer.to_string(depth + by), layer)}}
          _invalid -> {:halt, {:error, {name, :policy, {:invalid, :depth}}}}
        end
      end)

    with {:ok, depths} <- depths do
      pack = Map.put(pack, "agents", agents)

      {:ok, if(depths == %{}, do: pack, else: put_in(pack, ["policy", "depth"], depths))}
    end
  end

  defp shift(name, _pack, _by), do: {:error, {name, :depth, :invalid}}

  # Each role becomes the config's model for it, each provider the config's.
  defp bind(name, pack, entry, dir) do
    roles = get_in(pack, ["pack", "roles"]) || []
    providers = get_in(pack, ["pack", "auth"]) || []
    models = Map.get(entry, "models", %{})
    auth = Map.get(entry, "auth", %{})

    with :ok <- covers(name, :models, roles, models),
         :ok <- covers(name, :auth, providers, auth),
         {:ok, agents} <- roles(name, Map.get(pack, "agents", %{}), models),
         {:ok, secrets} <- providers(name, Map.get(pack, "secrets", %{}), auth),
         {:ok, servers} <- server_secrets(name, get_in(pack, ["mcp", "servers"]) || [], auth) do
      servers = Enum.map(servers, &found_command(&1, dir))
      {:ok, %{agents: agents, secrets: secrets, servers: servers, pack: pack}}
    end
  end

  defp covers(name, kind, declared, mapped) when is_map(mapped) do
    case {declared -- Map.keys(mapped), Map.keys(mapped) -- declared} do
      {[], []} -> :ok
      {[missing | _], _} -> {:error, {name, kind, {:unmapped, missing}}}
      {[], [extra | _]} -> {:error, {name, kind, {:unknown, extra}}}
    end
  end

  defp covers(name, kind, _declared, _mapped), do: {:error, {name, kind, :not_a_table}}

  defp roles(name, agents, models) do
    Enum.reduce_while(agents, {:ok, %{}}, fn {agent, table}, {:ok, acc} ->
      case Map.fetch(models, Map.get(table, "model")) do
        {:ok, model} -> {:cont, {:ok, Map.put(acc, agent, Map.put(table, "model", model))}}
        :error -> {:halt, {:error, {name, :agents, {:no_role, agent}}}}
      end
    end)
  end

  defp providers(name, secrets, auth) do
    Enum.reduce_while(secrets, {:ok, %{}}, fn {tool, table}, {:ok, acc} ->
      case mapped(table, auth) do
        {:ok, table} -> {:cont, {:ok, Map.put(acc, tool, table)}}
        :error -> {:halt, {:error, {name, :secrets, {:no_provider, tool}}}}
      end
    end)
  end

  defp server_secrets(name, servers, auth) do
    Enum.reduce_while(servers, {:ok, []}, fn server, {:ok, acc} ->
      case mapped(Map.get(server, "secrets", %{}), auth) do
        {:ok, secrets} when secrets == %{} -> {:cont, {:ok, acc ++ [server]}}
        {:ok, secrets} -> {:cont, {:ok, acc ++ [Map.put(server, "secrets", secrets)]}}
        :error -> {:halt, {:error, {name, :mcp, {:no_provider, server["name"]}}}}
      end
    end)
  end

  defp found_command(%{"command" => [program | args]} = server, dir) when is_binary(program) do
    if String.contains?(program, "/"),
      do: Map.put(server, "command", [Path.expand(program, dir) | args]),
      else: server
  end

  defp found_command(server, _dir), do: server

  defp mapped(table, auth) do
    Enum.reduce_while(table, {:ok, %{}}, fn {secret, provider}, {:ok, acc} ->
      case Map.fetch(auth, provider) do
        {:ok, local} -> {:cont, {:ok, Map.put(acc, secret, local)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # The pack's items under the config's: the config's of a name overrides
  # them key by key; two packs' of a name are refused.
  defp lay(name, bound, data, owners) do
    tables = [
      {["agents"], bound.agents},
      {["workflows"], Map.get(bound.pack, "workflows", %{})},
      {["secrets"], bound.secrets},
      {["policy", "depth"], get_in(bound.pack, ["policy", "depth"]) || %{}}
    ]

    with :ok <- only_depths(name, Map.get(bound.pack, "policy", %{})),
         {:ok, data, owners} <- lay_tables(name, tables, data, owners) do
      lay_servers(name, bound.servers, data, owners)
    end
  end

  defp only_depths(name, policy) do
    case Map.keys(policy) -- ["depth"] do
      [] -> :ok
      [key | _] -> {:error, {name, :policy, {:unknown_key, key}}}
    end
  end

  defp lay_tables(name, tables, data, owners) do
    Enum.reduce_while(tables, {:ok, data, owners}, fn {path, items}, {:ok, data, owners} ->
      local = get_in(data, path) || %{}

      Enum.reduce_while(items, {:ok, local, owners}, fn {key, item}, {:ok, merged, owners} ->
        owner = Map.get(owners, {path, key})

        cond do
          owner ->
            {:halt, {:error, {name, :conflict, {Enum.join(path, "."), key, owner}}}}

          true ->
            item = overridden(item, Map.get(local, key, %{}))
            {:cont, {:ok, Map.put(merged, key, item), Map.put(owners, {path, key}, name)}}
        end
      end)
      |> case do
        {:ok, merged, owners} -> {:cont, {:ok, put(data, path, merged), owners}}
        error -> {:halt, error}
      end
    end)
  end

  # `granted` is the config's name for tools added to a layer: written over
  # a pack's layer, the grants join the pack's tools.
  defp overridden(%{"tools" => tools} = item, %{"granted" => granted} = local)
       when is_list(tools) and is_list(granted) do
    item
    |> Map.merge(Map.delete(local, "granted"))
    |> Map.put("tools", Enum.uniq(tools ++ granted))
  end

  defp overridden(item, local), do: Map.merge(item, local)

  defp lay_servers(name, servers, data, owners) do
    local = get_in(data, ["mcp", "servers"]) || []
    names = MapSet.new(local, & &1["name"])

    Enum.reduce_while(servers, {:ok, local, owners}, fn server, {:ok, merged, owners} ->
      key = {["mcp", "servers"], server["name"]}

      cond do
        owner = Map.get(owners, key) ->
          {:halt, {:error, {name, :conflict, {"mcp.servers", server["name"], owner}}}}

        MapSet.member?(names, server["name"]) ->
          {:cont, {:ok, merged, owners}}

        true ->
          {:cont, {:ok, merged ++ [server], Map.put(owners, key, name)}}
      end
    end)
    |> case do
      {:ok, [], owners} -> {:ok, data, owners}
      {:ok, merged, owners} -> {:ok, put(data, ["mcp", "servers"], merged), owners}
      error -> error
    end
  end

  defp put(data, [key], value), do: Map.put(data, key, value)

  defp put(data, [key | rest], value),
    do: Map.put(data, key, put(Map.get(data, key, %{}), rest, value))

  # The pack's tools and skills before the config's own.
  defp paths(data, dir) do
    Enum.reduce([{"tools", "tools"}, {"skills", "skills"}], data, fn {table, folder}, data ->
      found = Path.join(dir, folder)

      if File.dir?(found) do
        Map.update(data, table, %{"paths" => [found]}, fn table ->
          Map.update(table, "paths", [found], &[found | &1])
        end)
      else
        data
      end
    end)
  end
end
