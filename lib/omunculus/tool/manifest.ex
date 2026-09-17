defmodule Omunculus.Tool.Manifest do
  @moduledoc """
  Struct parsed from a `tool.toml` or `hook.toml`, per spec §8.5. An entry
  built from an MCP server's `tools/list` (spec §8.7) sets `mcp` instead of
  going through `load/1`.
  """

  @enforce_keys [:name, :kind, :dir]
  defstruct name: nil,
            kind: nil,
            shape: "simple",
            triggers: ["model"],
            description: "",
            tags: [],
            groups: [],
            command: nil,
            module: nil,
            parameters: %{},
            views: [],
            events: [],
            agent: nil,
            dir: nil,
            mcp: nil,
            config: true

  @type t :: %__MODULE__{
          name: String.t(),
          kind: String.t(),
          shape: String.t(),
          triggers: [String.t()],
          description: String.t(),
          tags: [String.t()],
          groups: [String.t()],
          command: [String.t()] | nil,
          module: String.t() | nil,
          parameters: map,
          views: [String.t()],
          events: [String.t()],
          agent: String.t() | nil,
          dir: String.t() | nil,
          mcp: Omunculus.Config.mcp_server() | nil,
          config: boolean
        }

  @known_keys ~w(name kind shape triggers description tags groups command module parameters views events agent config)

  @spec load(String.t()) :: {:ok, t} | {:error, term}
  def load(path) do
    with {:ok, raw} <- Toml.decode_file(path) do
      parse(raw, Path.dirname(path))
    end
  end

  @spec parse(map, String.t()) :: {:ok, t} | {:error, term}
  def parse(raw, dir) when is_map(raw) and is_binary(dir) do
    build(raw, dir)
  end

  @spec card(t | map) :: String.t()
  def card(%__MODULE__{name: name, description: description, tags: tags}) do
    format_card(name, description, tags)
  end

  def card(%{name: name, description: description} = card) do
    tags = Map.get(card, :tags) || Map.get(card, "tags") || []
    format_card(name, description, tags)
  end

  defp format_card(name, description, tags) do
    lines =
      description
      |> String.split("\n")
      |> Enum.take(3)
      |> Enum.join("\n")

    "- #{name}: #{lines}" <> tags_suffix(tags)
  end

  defp tags_suffix([]), do: ""
  defp tags_suffix(nil), do: ""
  defp tags_suffix(tags), do: " [tags: #{Enum.join(tags, ", ")}]"

  @spec triggered_by?(t, String.t()) :: boolean
  def triggered_by?(%__MODULE__{triggers: triggers}, trigger), do: trigger in triggers

  defp build(raw, dir) do
    case Enum.find(Map.keys(raw), &(&1 not in @known_keys)) do
      nil -> validate(raw, dir)
      unknown -> {:error, {:unknown_key, unknown}}
    end
  end

  defp validate(raw, dir) do
    with {:ok, name} <- required_string(raw, "name"),
         {:ok, kind} <- required_enum(raw, "kind", ["tool", "hook"]),
         {:ok, {command, module}} <- required_command_or_module(raw),
         {:ok, shape} <- optional_string(raw, "shape", "simple"),
         {:ok, description} <- optional_string(raw, "description", ""),
         {:ok, tags} <- optional_string_list(raw, "tags", []),
         {:ok, groups} <- optional_string_list(raw, "groups", []),
         {:ok, parameters} <- optional_map(raw, "parameters", %{}),
         {:ok, views} <- optional_string_list(raw, "views", []),
         {:ok, {triggers, events, agent}} <- kind_fields(raw, kind),
         {:ok, config} <- optional_bool(raw, "config", true),
         :ok <- check_config_flag(name, kind, triggers, config) do
      {:ok,
       %__MODULE__{
         name: name,
         kind: kind,
         shape: shape,
         triggers: triggers,
         description: description,
         tags: tags,
         groups: groups,
         command: command,
         module: module,
         parameters: parameters,
         views: views,
         events: events,
         agent: agent,
         dir: dir,
         config: config
       }}
    end
  end

  defp check_config_flag(_name, _kind, _triggers, true), do: :ok
  defp check_config_flag("preset", "tool", ["cli"], false), do: :ok
  defp check_config_flag(_name, _kind, _triggers, false), do: {:error, {:invalid, :config}}

  defp kind_fields(raw, "tool") do
    with :ok <- forbidden(raw, "events"),
         :ok <- forbidden(raw, "agent"),
         {:ok, triggers} <-
           optional_enum_list(raw, "triggers", ["model"], ["model", "cli", "harness"]),
         :ok <- validate_harness_triggers(triggers) do
      {:ok, {triggers, [], nil}}
    end
  end

  defp kind_fields(raw, "hook") do
    with :ok <- forbidden(raw, "triggers"),
         {:ok, events} <- required_string_list(raw, "events"),
         {:ok, agent} <- optional_agent(raw) do
      {:ok, {[], events, agent}}
    end
  end

  defp validate_harness_triggers(["harness"]), do: :ok

  defp validate_harness_triggers(triggers) do
    if "harness" in triggers, do: {:error, {:invalid, :triggers}}, else: :ok
  end

  defp forbidden(raw, key) do
    if Map.has_key?(raw, key), do: {:error, {:invalid, String.to_atom(key)}}, else: :ok
  end

  defp optional_agent(raw) do
    case Map.fetch(raw, "agent") do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, :agent}}
    end
  end

  defp required_command_or_module(raw) do
    case {Map.fetch(raw, "command"), Map.fetch(raw, "module")} do
      {{:ok, _}, :error} ->
        with {:ok, command} <- required_string_list(raw, "command"), do: {:ok, {command, nil}}

      {:error, {:ok, _}} ->
        with {:ok, module} <- required_string(raw, "module"), do: {:ok, {nil, module}}

      _ ->
        {:error, {:invalid, :command}}
    end
  end

  defp required_string(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp required_enum(raw, key, allowed) do
    with {:ok, value} <- required_string(raw, key) do
      if value in allowed, do: {:ok, value}, else: {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp required_string_list(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, [_ | _] = value} ->
        if Enum.all?(value, &is_binary/1),
          do: {:ok, value},
          else: {:error, {:invalid, String.to_atom(key)}}

      _ ->
        {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp optional_string(raw, key, default) do
    case Map.fetch(raw, key) do
      :error -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp optional_string_list(raw, key, default) do
    case Map.fetch(raw, key) do
      :error ->
        {:ok, default}

      {:ok, value} when is_list(value) ->
        if Enum.all?(value, &is_binary/1),
          do: {:ok, value},
          else: {:error, {:invalid, String.to_atom(key)}}

      _ ->
        {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp optional_enum_list(raw, key, default, allowed) do
    with {:ok, value} <- optional_string_list(raw, key, default) do
      if Enum.all?(value, &(&1 in allowed)),
        do: {:ok, value},
        else: {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp optional_map(raw, key, default) do
    case Map.fetch(raw, key) do
      :error -> {:ok, default}
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp optional_bool(raw, key, default) do
    case Map.fetch(raw, key) do
      :error -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end
end
