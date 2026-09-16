defmodule Omunculus.Fixtures do
  @moduledoc """
  Inserts rows behind the store's back so tests can set up state the
  actions of the current stage cannot create yet.
  """

  alias Omunculus.Config
  alias Omunculus.Id
  alias Omunculus.Store.Query

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
    if toml, do: write_config(dir, toml)
    {:ok, config} = Config.load(dir)
    config
  end

  @spec write_config(String.t(), String.t()) :: :ok
  def write_config(dir, toml) do
    File.write!(Path.join(dir, "omunculus.toml"), toml <> "\n" <> @execution)
  end
end
