defmodule Omunculus.Fixtures do
  @moduledoc """
  Inserts rows behind the store's back so tests can set up state the
  actions of the current stage cannot create yet.
  """

  alias Omunculus.Config
  alias Omunculus.Id
  alias Omunculus.Store.Query
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

  @spec config(String.t() | nil) :: Config.t()
  def config(toml \\ nil) do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)

    case toml do
      nil -> install_default(dir)
      contents -> write_config(dir, contents)
    end

    {:ok, config} = load_config(dir)
    config
  end

  @spec write_config(String.t(), String.t()) :: :ok
  def write_config(dir, toml) do
    body = toml <> "\n" <> @execution
    body = if String.contains?(toml, "[tools]"), do: body, else: body <> "\n" <> tools_table(dir)
    File.write!(config_path(dir), body)
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
