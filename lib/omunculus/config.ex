defmodule Omunculus.Config do
  @moduledoc false

  @default_max_turns 32
  @default_preset "coding"
  @default_timestamp_format "%H:%M:%S"

  def load(opts) when is_list(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    explicit = Keyword.get(opts, :config_file)
    env = Keyword.get(opts, :env, %{})

    sources =
      case explicit do
        path when is_binary(path) and path != "" -> [path]
        _ -> [global_path(), Path.join(cwd, "omunculus.toml")]
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
      defaults: %{preset: @default_preset, max_turns: @default_max_turns},
      chat: %{api: "openai-completions", auth: nil, base_url: nil, model: nil, api_key: nil},
      output: %{timestamp_format: @default_timestamp_format},
      interceptors: [],
      automations: [],
      presets: %{
        "coding" => %{
          tools: Omunculus.Tools.default_names(),
          instructions: nil,
          max_turns: nil
        },
        "plan" => %{
          tools: ["read", "grep", "find", "ls"],
          instructions: "Do not alter files. Explore and return a plan.",
          max_turns: 16
        }
      }
    }
  end

  def resolve(config, flags) when is_map(flags) do
    preset_name = flags["preset"] || flags[:preset] || config.defaults.preset
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
    with {:ok, interceptors} <- check_interceptors(config.interceptors),
         {:ok, automations} <- check_automations(config.automations) do
      {:ok, %{interceptors: interceptors, automations: automations}}
    end
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

  defp check_automations(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      with :ok <- require_name(item, :automation),
           :ok <- check_events(item, fn _ -> true end, :never),
           :ok <-
             if(is_binary(item.run) and item.run != "",
               do: :ok,
               else: {:error, {:automation_requires_run, item.name}}
             ) do
        {:cont, {:ok, acc ++ [item]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

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
              {:ok, from_toml(expanded)}
            end

          {:error, _} ->
            {:ok, %{}}
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
    presets = Map.get(map, "presets", %{})
    interceptors = Map.get(map, "interceptors", [])
    automations = Map.get(map, "automations", [])

    %{
      defaults: %{
        preset: defaults["preset"],
        max_turns: parse_int(defaults["max_turns"])
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
        Enum.map(List.wrap(interceptors), fn item ->
          %{
            name: item["name"],
            events: item["events"],
            module: item["module"],
            options: item["options"] || %{}
          }
        end),
      automations:
        Enum.map(List.wrap(automations), fn item ->
          %{name: item["name"], events: item["events"], run: item["run"]}
        end),
      presets:
        presets
        |> Enum.map(fn {name, body} ->
          {name,
           %{
             tools: body["tools"],
             instructions: body["instructions"],
             max_turns: parse_int(body["max_turns"])
           }}
        end)
        |> Map.new()
    }
  end

  defp merge(base, overlay) when overlay == %{}, do: base

  defp merge(base, overlay) do
    %{
      defaults: deep_keep(base.defaults, Map.get(overlay, :defaults, %{})),
      chat: deep_keep(base.chat, Map.get(overlay, :chat, %{})),
      output: deep_keep(base.output, Map.get(overlay, :output, %{})),
      interceptors: base.interceptors ++ Map.get(overlay, :interceptors, []),
      automations: base.automations ++ Map.get(overlay, :automations, []),
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
