defmodule Omunculus.Config do
  @moduledoc false

  @default_max_turns 32
  @default_preset "coding"
  @default_timestamp_format "%H:%M:%S"
  @policy_keys ~w(mode granted negotiable human deny directory)

  def load(opts) when is_list(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    explicit = Keyword.get(opts, :config_file)
    env = Keyword.get(opts, :env, %{})

    project_path = Path.join(cwd, "omunculus.toml")

    sources =
      case explicit do
        path when is_binary(path) and path != "" ->
          if Path.expand(path, cwd) == Path.expand(project_path, cwd) do
            [project_path]
          else
            [project_path, path]
          end

        _ ->
          [global_path(), project_path]
      end

    Enum.reduce_while(sources, {:ok, empty()}, fn path, {:ok, acc} ->
      case read_file(path, env) do
        {:ok, overlay} -> {:cont, {:ok, merge(acc, overlay)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def empty do
    %{
      defaults: %{preset: @default_preset, max_turns: @default_max_turns, max_retries: 2},
      chat: %{api: "openai-completions", auth: nil, base_url: nil, model: nil, api_key: nil},
      output: %{timestamp_format: @default_timestamp_format},
      interceptors: [],
      automations: [],
      agents: %{},
      prompts: %{},
      teams: %{},
      workspaces: %{},
      policy: %{},
      session: %{},
      presets: %{
        "coding" => %{
          tools: Omunculus.Tools.default_names(),
          instructions: nil,
          max_turns: nil
        },
        "plan" => %{
          tools: ["read", "grep", "find", "ls"],
          instructions: "Do not alter files. Explore and return a plan.",
          max_turns: 16,
          policy: %{"mode" => "deny", "granted" => ["read", "grep", "find", "ls"]}
        }
      }
    }
  end

  def resolve(config, flags) when is_map(flags) do
    preset_name =
      flags["profile"] || flags["preset"] || flags[:profile] || flags[:preset] ||
        config.defaults.preset

    tools_flag = flags["tools"] || flags[:tools]

    with {:ok, preset} <- fetch_preset(config, preset_name),
         {:ok, tools} <- resolve_tools(preset, tools_flag),
         :ok <- Omunculus.Tools.validate_names(tools),
         :ok <- validate_timestamp_format(config.output.timestamp_format) do
      max_turns =
        parse_int(flags["max_turns"] || flags[:max_turns]) ||
          preset.max_turns ||
          config.defaults.max_turns ||
          @default_max_turns

      {:ok,
       %{
         preset: preset_name,
         tools: tools,
         instructions: preset.instructions,
         max_turns: max_turns,
         chat: config.chat,
         output: config.output
       }}
    end
  end

  @doc """
  Validate `[[interceptors]]` and `[[automations]]` against the event catalog
  and the loaded modules. Returns `{:ok, %{interceptors: [...], automations: [...]}}`
  with resolved modules, or the first error.
  """
  def check(config) do
    with :ok <- check_workflow_config(config),
         :ok <- check_references(config),
         {:ok, interceptors} <- check_interceptors(config.interceptors),
         {:ok, automations} <- check_automations(config.automations, config),
         {:ok, policy} <- check_policy_fit(config) do
      {:ok, %{interceptors: interceptors, automations: automations, policy: policy}}
    end
  end

  defp check_workflow_config(config) do
    entries =
      [{"defaults", config.defaults}] ++
        Enum.map(config.agents, fn {k, v} -> {"agents.#{k}", v} end) ++
        Enum.map(config.presets, fn {k, v} -> {"profiles.#{k}", v} end)

    with :ok <-
           each(entries, fn {where, entry} ->
             value = entry[:max_retries]

             if is_nil(value) or (is_integer(value) and value >= 0),
               do: :ok,
               else: {:error, {:invalid_max_retries, where, value}}
           end) do
      each(config[:prompts] || %{}, fn {layer, entries} ->
        if layer in ["depth", "kind", "reason"] and is_map(entries) and
             Enum.all?(entries, fn {_, text} -> is_binary(text) end),
           do: :ok,
           else: {:error, {:invalid_prompt_layer, layer}}
      end)
    end
  end

  # Teams reference agents, workspaces reference teams, roles reference
  # agents; every reference must resolve. Policy bands are only shape-checked
  # here: normalisation against the tool catalog is the next step.
  defp check_references(config) do
    agents = Enum.uniq(Map.keys(config.agents) ++ Map.keys(Omunculus.Runtime.Agents.defaults()))
    teams = Map.keys(config.teams)

    with :ok <- each(config.teams, fn {name, team} -> check_team(name, team, agents) end),
         :ok <-
           each(config.workspaces, fn {name, ws} ->
             case Enum.find(ws.teams || [], &(&1 not in teams)) do
               nil -> :ok
               missing -> {:error, {:unknown_team, name, missing}}
             end
           end),
         :ok <-
           each(config.session[:roles] || %{}, fn {depth, agent} ->
             if agent in agents or config.agents == %{},
               do: :ok,
               else: {:error, {:unknown_agent, "session.roles.#{depth}", agent}}
           end) do
      each(policy_entries(config), fn {where, policy} -> check_policy(where, policy) end)
    end
  end

  defp check_team(name, team, agents) do
    cond do
      is_nil(team.lead) ->
        {:error, {:team_requires_lead, name}}

      team.lead not in agents ->
        {:error, {:unknown_agent, "teams.#{name}.lead", team.lead}}

      member = Enum.find(team.members || [], &(&1 not in agents)) ->
        {:error, {:unknown_agent, "teams.#{name}.members", member}}

      team.scope not in [nil, "task", "node"] ->
        {:error, {:invalid_team_scope, name, team.scope}}

      true ->
        :ok
    end
  end

  defp policy_entries(config) do
    Enum.map(config.workspaces, fn {n, ws} -> {"workspaces.#{n}", ws.policy} end) ++
      Enum.map(config.presets, fn {n, p} -> {"profiles.#{n}", p[:policy] || %{}} end) ++
      Enum.map(config.policy, fn {d, p} -> {"policy.depth.#{d}", p} end)
  end

  defp check_policy(where, policy) do
    cond do
      policy["mode"] not in [nil, "allow", "deny"] ->
        {:error, {:invalid_policy_mode, where, policy["mode"]}}

      policy["directory"] not in [nil, "subtree", "session"] ->
        {:error, {:invalid_policy_directory, where, policy["directory"]}}

      key = Enum.find(~w(granted negotiable human deny), &(not is_list(policy[&1] || []))) ->
        {:error, {:invalid_policy_list, where, key}}

      true ->
        :ok
    end
  end

  defp check_policy_fit(config) do
    pin = config.session[:tools_catalog]
    current = Omunculus.Tools.catalog_version()

    with :ok <- check_tools_catalog(pin, current),
         table when is_map(table) <- policy_table(config) do
      {:ok, table}
    end
  end

  defp check_tools_catalog(nil, _current), do: :ok
  defp check_tools_catalog(pin, current) when pin in [nil, current], do: :ok
  defp check_tools_catalog(pin, current), do: {:error, {:stale_tools_catalog, pin, current}}

  defp policy_table(config) do
    case Omunculus.Policy.table(config) do
      {:error, reason} -> {:error, reason}
      table -> table
    end
  end

  defp each(enum, fun) do
    Enum.reduce_while(enum, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_interceptors(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      with :ok <- require_name(item, :interceptor),
           :ok <- check_events(item, &Omunculus.Events.interceptable?/1, :not_interceptable),
           {:ok, module} <- Omunculus.Interceptor.resolve(item.module || "") do
        {:cont, {:ok, acc ++ [%{item | module: module}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_automations(list, config) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      with :ok <- require_name(item, :automation),
           :ok <- check_events(item, fn _ -> true end, :never),
           :ok <-
             if(is_binary(item.run) and item.run != "",
               do: :ok,
               else: {:error, {:automation_requires_run, item.name}}
             ),
           :ok <- check_may_request(item, config) do
        {:cont, {:ok, acc ++ [item]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_may_request(%{may_request: may} = item, config) when is_map(may) do
    profiles = Map.keys(config.presets)
    workspaces = Map.keys(config.workspaces)

    cond do
      p = Enum.find(may["profiles"] || [], &(&1 not in profiles)) ->
        {:error, {:unknown_profile, "automations.#{item.name}.may_request", p}}

      w = Enum.find(may["workspaces"] || [], &(&1 not in workspaces)) ->
        {:error, {:unknown_workspace, "automations.#{item.name}.may_request", w}}

      true ->
        :ok
    end
  end

  defp check_may_request(_item, _config), do: :ok

  defp require_name(%{name: name}, _kind) when is_binary(name) and name != "", do: :ok
  defp require_name(_item, kind), do: {:error, {:config_entry_requires_name, kind}}

  defp check_events(%{name: name, events: events}, allowed?, reason) do
    cond do
      not is_list(events) or events == [] ->
        {:error, {:config_entry_requires_events, name}}

      type = Enum.find(events, &(not Omunculus.Events.known?(&1))) ->
        {:error, {:unknown_event_type, name, type}}

      type = Enum.find(events, &(not allowed?.(&1))) ->
        {:error, {reason, name, type}}

      true ->
        :ok
    end
  end

  defp fetch_preset(_config, nil), do: fetch_preset(empty(), @default_preset)

  defp fetch_preset(config, name) do
    case Map.get(config.presets, name) do
      nil -> {:error, {:unknown_preset, name}}
      preset -> {:ok, preset}
    end
  end

  defp resolve_tools(_preset, tools) when is_list(tools) and tools != "", do: {:ok, tools}

  defp resolve_tools(_preset, tools) when is_binary(tools) do
    {:ok, String.split(tools, ",", trim: true)}
  end

  defp resolve_tools(preset, _), do: {:ok, preset.tools || Omunculus.Tools.default_names()}

  defp global_path do
    Path.join([System.user_home!(), ".omunculus", "config.toml"])
  end

  defp read_file(path, env) do
    case File.read(path) do
      {:ok, body} ->
        case Toml.decode(body) do
          {:ok, map} ->
            with {:ok, expanded} <- expand_env(map, env) do
              config = from_toml(expanded)

              workspaces =
                Map.new(config.workspaces, fn {name, ws} ->
                  {name,
                   %{
                     ws
                     | roots:
                         Enum.map(ws.roots, &Path.expand(&1, Path.dirname(Path.expand(path))))
                   }}
                end)

              {:ok, %{config | workspaces: workspaces}}
            end

          {:error, reason} ->
            {:error, {:invalid_toml, path, reason}}
        end

      {:error, _} ->
        {:ok, %{}}
    end
  end

  defp expand_env(value, env) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case expand_env(item, env) do
        {:ok, expanded} -> {:cont, {:ok, Map.put(acc, key, expanded)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp expand_env(value, env) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case expand_env(item, env) do
        {:ok, expanded} -> {:cont, {:ok, [expanded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  defp expand_env(value, env) when is_binary(value) do
    case Regex.run(~r/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/, value) do
      [_, name] ->
        case Map.fetch(env, name) do
          {:ok, expanded} -> {:ok, expanded}
          :error -> {:error, {:missing_config_env, name}}
        end

      nil ->
        {:ok, value}
    end
  end

  defp expand_env(value, _env), do: {:ok, value}

  defp from_toml(map) when is_map(map) do
    defaults = Map.get(map, "defaults", %{})
    chat = Map.get(map, "chat", %{})
    output = Map.get(map, "output", %{})
    # [profiles] absorbs [presets]; both are accepted, profiles win on clash.
    presets = Map.merge(Map.get(map, "presets", %{}), Map.get(map, "profiles", %{}))
    interceptors = named_entries(Map.get(map, "interceptors", []))
    automations = named_entries(Map.get(map, "automations", []))
    policy_depth = map |> Map.get("policy", %{}) |> Map.get("depth", %{})
    session = Map.get(map, "session", %{})

    %{
      defaults: %{
        preset: defaults["preset"],
        max_turns: parse_int(defaults["max_turns"]),
        max_retries: defaults["max_retries"]
      },
      chat: %{
        api: chat["api"],
        auth: chat["auth"],
        base_url: chat["base_url"],
        model: chat["model"],
        api_key: chat["api_key"]
      },
      output: %{
        timestamp_format: output["timestamp_format"]
      },
      interceptors:
        Enum.map(interceptors, fn item ->
          %{
            name: item["name"],
            events: item["events"],
            module: item["module"],
            options: item["options"] || %{},
            workspaces: item["workspaces"]
          }
        end),
      automations:
        Enum.map(automations, fn item ->
          %{
            name: item["name"],
            events: item["events"],
            run: item["run"],
            may_request: item["may_request"]
          }
        end),
      prompts: Map.get(map, "prompts", %{}),
      agents:
        Map.new(Map.get(map, "agents", %{}), fn {name, body} ->
          {name,
           %{
             prompt: body["prompt"],
             kind: body["kind"],
             max_retries: body["max_retries"],
             model: body["model"],
             max_turns: parse_int(body["max_turns"])
           }}
        end),
      teams:
        Map.new(Map.get(map, "teams", %{}), fn {name, body} ->
          {name,
           %{
             lead: body["lead"],
             members: body["members"] || [],
             profile: body["profile"],
             scope: body["scope"]
           }}
        end),
      workspaces:
        Map.new(Map.get(map, "workspaces", %{}), fn {name, body} ->
          {name, %{roots: body["roots"] || [], teams: body["teams"], policy: policy_of(body)}}
        end),
      policy: Map.new(policy_depth, fn {depth, body} -> {to_string(depth), policy_of(body)} end),
      session: %{
        roles: session["roles"],
        cross_lineage: session["cross_lineage"],
        tools_catalog: session["tools_catalog"]
      },
      presets:
        presets
        |> Enum.map(fn {name, body} ->
          {name,
           %{
             tools: body["tools"],
             instructions: body["instructions"],
             max_retries: body["max_retries"],
             max_turns: parse_int(body["max_turns"]),
             policy: policy_of(body)
           }}
        end)
        |> Map.new()
    }
  end

  # [[section]] arrays with `name` and [section.name] tables are the same thing.
  defp named_entries(list) when is_list(list), do: list

  defp named_entries(map) when is_map(map),
    do: Enum.map(map, fn {name, body} -> Map.put(body, "name", name) end)

  defp named_entries(_), do: []

  defp policy_of(body) when is_map(body), do: Map.take(body, @policy_keys)
  defp policy_of(_), do: %{}

  defp merge(base, overlay) when overlay == %{}, do: base

  defp merge(base, overlay) do
    %{
      defaults: deep_keep(base.defaults, Map.get(overlay, :defaults, %{})),
      chat: deep_keep(base.chat, Map.get(overlay, :chat, %{})),
      output: deep_keep(base.output, Map.get(overlay, :output, %{})),
      interceptors: base.interceptors ++ Map.get(overlay, :interceptors, []),
      automations: base.automations ++ Map.get(overlay, :automations, []),
      agents: Map.merge(base.agents, Map.get(overlay, :agents, %{})),
      prompts: Map.merge(base[:prompts] || %{}, Map.get(overlay, :prompts, %{})),
      teams: Map.merge(base.teams, Map.get(overlay, :teams, %{})),
      workspaces: Map.merge(base.workspaces, Map.get(overlay, :workspaces, %{})),
      policy: Map.merge(base.policy, Map.get(overlay, :policy, %{})),
      session: deep_keep(base.session, Map.get(overlay, :session, %{})),
      presets: Map.merge(base.presets, Map.get(overlay, :presets, %{}))
    }
  end

  defp deep_keep(base, overlay) do
    Map.merge(base, overlay, fn _k, a, b -> if is_nil(b), do: a, else: b end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp validate_timestamp_format(format) when is_binary(format) do
    Calendar.strftime(DateTime.utc_now(), format)
    :ok
  rescue
    ArgumentError -> {:error, {:invalid_timestamp_format, format}}
  end

  defp validate_timestamp_format(format), do: {:error, {:invalid_timestamp_format, format}}
end
