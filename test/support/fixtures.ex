defmodule Omunculus.Fixtures do
  @moduledoc """
  Inserts rows behind the store's back so tests can set up state the
  actions of the current stage cannot create yet.
  """

  alias Omunculus.Config
  alias Omunculus.Id
  alias Omunculus.Project
  alias Omunculus.Store.Query
  alias Omunculus.Test.ScriptedModel
  alias Omunculus.Tools.Preset

  @now "2026-01-01T00:00:00Z"
  @execution """
  [execution]
  backend = "bubblewrap"
  runtimes = ["/usr"]
  environment = ["LANG", "LC_ALL", "TERM"]
  timeout_ms = 30000
  max_output_bytes = 1048576
  max_concurrent = 4
  max_queue = 64
  queue_timeout_ms = 30000
  """

  @defaults %{
    prompts: %{kind: "message", body: "hi", created_at: @now},
    events: %{type: "comment", body: "{}", at: @now},
    runs: %{agent: "concierge", depth: "0", status: "open"},
    comments: %{author: "agent", kind: "note", body: "note", created_at: @now},
    works: %{title: "a work", state: "open", created_at: @now},
    requests: %{
      agent: "concierge",
      ask: ~s({"kind":"tool","name":"write"}),
      arbiter: "human",
      status: "waiting_human",
      created_at: @now
    },
    inbox: %{agent: "concierge", created_at: @now}
  }

  @spec insert(Exqlite.Sqlite3.db(), atom, map) :: String.t()
  def insert(conn, table, attrs \\ %{}) do
    row =
      @defaults
      |> Map.fetch!(table)
      |> Map.put(:id, Id.new())
      |> Map.merge(attrs)

    :ok = Query.insert(conn, table, row)
    row.id
  end

  @spec config(String.t() | nil, keyword) :: Config.t()
  def config(toml \\ nil, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)

    case toml do
      nil ->
        install_default(dir)

        case Keyword.get(opts, :model) do
          fun when is_function(fun) -> use_model(dir, fun)
          _ -> :ok
        end

      contents ->
        write_config(dir, contents, opts)
    end

    {:ok, config} = load_config(dir)
    config
  end

  @spec write_config(String.t(), String.t(), keyword) :: :ok
  def write_config(dir, toml, opts \\ []) when is_list(opts) do
    body = toml <> "\n" <> @execution
    body = if String.contains?(toml, "[tools]"), do: body, else: body <> "\n" <> tools_table(dir)
    File.write!(config_path(dir), body)
    apply_defaults(dir, opts)
  end

  @spec open_project(String.t()) :: {:ok, Project.t()} | {:error, term}
  def open_project(dir) do
    with {:ok, config} <- load_config(dir) do
      Project.open(config)
    end
  end

  @spec use_model(String.t() | Project.t(), fun) :: :ok
  def use_model(%Project{dir: dir}, fun), do: use_model(dir, fun)

  def use_model(dir, fun) when is_binary(dir) and is_function(fun),
    do: apply_defaults(dir, model: fun)

  defp apply_defaults(dir, opts) do
    path = config_path(dir)

    case Toml.decode_file(path) do
      {:ok, data} -> File.write!(path, Config.Toml.encode(inject_defaults(data, opts)))
      _invalid -> :ok
    end
  end

  defp inject_defaults(data, opts) do
    data = maybe_put_store(data)

    case Keyword.get(opts, :model) do
      fun when is_function(fun) ->
        id = Id.new()
        ScriptedModel.put(id, fun)

        data
        |> put_model("scripted", scripted_spec(id))
        |> put_agent_models("scripted")

      _absent ->
        case Map.get(data, "models") do
          models when is_map(models) and map_size(models) > 0 ->
            data

          _ ->
            data
            |> put_model("fake", %{
              "api" => "module",
              "module" => "Omunculus.Model.Fake"
            })
            |> put_missing_agent_models("fake")
        end
    end
  end

  defp put_model(data, name, spec) do
    models = data |> Map.get("models") |> then(&if(is_map(&1), do: &1, else: %{}))
    Map.put(data, "models", Map.put(models, name, spec))
  end

  defp scripted_spec(id) do
    %{
      "api" => "module",
      "module" => "Omunculus.Test.ScriptedModel",
      "params" => %{"script" => id}
    }
  end

  defp put_agent_models(data, name) do
    update_agents(data, fn agent -> put_agent_model(agent, name, true) end)
  end

  defp put_missing_agent_models(data, name) do
    update_agents(data, fn agent -> put_agent_model(agent, name, false) end)
  end

  defp update_agents(data, fun) do
    case Map.get(data, "agents") do
      agents when is_map(agents) ->
        Map.put(data, "agents", Map.new(agents, fn {name, agent} -> {name, fun.(agent)} end))

      _ ->
        data
    end
  end

  defp put_agent_model(agent, name, true) when is_map(agent), do: Map.put(agent, "model", name)

  defp put_agent_model(agent, name, false) when is_map(agent) do
    if Map.has_key?(agent, "model"), do: agent, else: Map.put(agent, "model", name)
  end

  defp put_agent_model(agent, _name, _force), do: agent

  defp maybe_put_store(data) do
    case Map.get(data, "store") do
      store when is_map(store) ->
        data

      _ ->
        Map.put(data, "store", %{"path" => ".omunculus/store.sqlite3"})
    end
  end

  @spec tools_table(String.t()) :: String.t()
  def tools_table(dir) do
    """
    [tools]
    paths = #{Jason.encode!([package_tools(), Path.join(dir, "tools")])}
    """
  end

  @spec package_tools() :: String.t()
  def package_tools, do: Application.app_dir(:omunculus, Path.join("priv", "tools"))

  @spec preset_dir(String.t()) :: String.t()
  def preset_dir(name),
    do: Path.join(Application.app_dir(:omunculus, Path.join("priv", "presets")), name)

  @spec config_path(String.t()) :: String.t()
  def config_path(dir), do: Path.join(dir, "omunculus.toml")

  @spec load_config(String.t()) :: {:ok, Config.t()} | {:error, term}
  def load_config(dir), do: Config.load(config_path(dir))

  @spec grant(String.t(), Config.grant_layer(), String.t()) :: :ok | {:error, term}
  def grant(dir, layer, name), do: Config.grant(config_path(dir), layer, name)

  @spec install_default(String.t()) :: :ok
  def install_default(dir) do
    %{"ok" => true} =
      Preset.run(%{
        args: %{"name" => "default", "from" => preset_dir("default")},
        config_path: config_path(dir)
      })

    :ok
  end
end
