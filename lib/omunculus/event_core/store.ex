defmodule Omunculus.EventCore.Store do
  @moduledoc """
  Thin SQLite/WAL access layer used only from inside the Event Core process.

  Tables follow docs/to-be/data-model.md: six domain/archive tables plus the
  central append-only `EVENTS` log. `PROJECTION_CURSORS` is the one additional
  store: it is a rebuildable checkpoint (last applied `sequence` per projection),
  never a copy of history, and exists so a consumer can apply an event and
  advance its cursor in the same transaction.
  """

  alias Exqlite.Sqlite3

  @schema [
    "PRAGMA journal_mode=WAL",
    "PRAGMA busy_timeout=5000",
    "PRAGMA foreign_keys=ON",
    """
    CREATE TABLE IF NOT EXISTS PROJECTS (
      project_id TEXT PRIMARY KEY,
      name TEXT,
      root TEXT,
      created_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS WORK_ITEMS (
      work_item_id TEXT PRIMARY KEY,
      project_id TEXT,
      workspace_id TEXT,
      parent_work_item_id TEXT,
      requested_by TEXT,
      instruction TEXT NOT NULL,
      status TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'active',
      version INTEGER NOT NULL DEFAULT 0,
      checkpoint TEXT,
      awaiting TEXT,
      result TEXT,
      created_at TEXT,
      updated_at TEXT,
      last_sequence INTEGER NOT NULL DEFAULT 0
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS COMMENTS (
      comment_id TEXT PRIMARY KEY,
      session_id TEXT,
      work_item_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      body TEXT,
      created_at TEXT,
      read_at TEXT,
      event_id TEXT,
      last_sequence INTEGER NOT NULL DEFAULT 0
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS WORK_ITEM_DEPENDENCIES (
      project_id TEXT,
      work_item_id TEXT NOT NULL,
      depends_on_work_item_id TEXT NOT NULL,
      last_sequence INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (work_item_id, depends_on_work_item_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ARCHIVE_RUNS (
      run_id TEXT PRIMARY KEY,
      project_id TEXT,
      work_item_id TEXT NOT NULL,
      attempt INTEGER NOT NULL,
      depth INTEGER NOT NULL,
      parent_run_id TEXT,
      originating_run_id TEXT,
      agent_id TEXT,
      agent_kind TEXT,
      trace_id TEXT,
      status TEXT NOT NULL,
      reason TEXT,
      outcome TEXT,
      policy_hash TEXT,
      started_at TEXT,
      finished_at TEXT,
      last_sequence INTEGER NOT NULL DEFAULT 0
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS ARCHIVE_MODEL_CALLS (
      call_id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      trace_id TEXT,
      round INTEGER,
      model TEXT,
      usage TEXT,
      outcome TEXT,
      duration_ms INTEGER,
      occurred_at TEXT,
      last_sequence INTEGER NOT NULL DEFAULT 0
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS EVENTS (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL,
      type TEXT NOT NULL,
      schema_version TEXT NOT NULL,
      payload TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      correlation_id TEXT NOT NULL,
      causation_id TEXT,
      idempotency_key TEXT UNIQUE,
      session_id TEXT,
      workspace_id TEXT,
      project_id TEXT,
      work_item_id TEXT,
      run_id TEXT,
      content_hash TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS events_correlation ON EVENTS (correlation_id, sequence)",
    "CREATE INDEX IF NOT EXISTS events_work_item ON EVENTS (work_item_id, sequence)",
    """
    CREATE TABLE IF NOT EXISTS PROJECTION_CURSORS (
      projection TEXT PRIMARY KEY,
      last_sequence INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS SESSION_WORKSPACES (
      workspace_id TEXT PRIMARY KEY,
      roots TEXT,
      teams TEXT,
      attached INTEGER NOT NULL DEFAULT 1,
      attached_at TEXT,
      last_sequence INTEGER NOT NULL DEFAULT 0
    )
    """
  ]

  @projection_tables ~w(PROJECTS WORK_ITEMS COMMENTS WORK_ITEM_DEPENDENCIES ARCHIVE_RUNS ARCHIVE_MODEL_CALLS SESSION_WORKSPACES)

  def projection_tables, do: @projection_tables

  def open(path) do
    with {:ok, conn} <- Sqlite3.open(path) do
      Enum.each(@schema, fn sql -> :ok = exec!(conn, sql) end)
      {:ok, conn}
    end
  end

  def close(conn), do: Sqlite3.close(conn)

  def exec!(conn, sql) do
    case Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> raise "sqlite execute failed: #{inspect(reason)} in #{sql}"
    end
  end

  @doc "Run a parameterized statement and return all rows."
  def query(conn, sql, args \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(stmt, Enum.map(args, &encode_arg/1))
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Sqlite3.release(conn, stmt)
    end
  end

  def one(conn, sql, args \\ []) do
    case query(conn, sql, args) do
      [row] -> row
      [] -> nil
      rows -> raise "expected at most one row, got #{length(rows)}"
    end
  end

  def transaction(conn, fun) when is_function(fun, 1) do
    exec!(conn, "BEGIN IMMEDIATE")

    try do
      result = fun.(conn)
      exec!(conn, "COMMIT")
      result
    rescue
      e ->
        _ = Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    catch
      :throw, value ->
        _ = Sqlite3.execute(conn, "ROLLBACK")
        throw(value)
    end
  end

  def last_insert_rowid(conn) do
    {:ok, id} = Sqlite3.last_insert_rowid(conn)
    id
  end

  defp encode_arg(nil), do: nil
  defp encode_arg(v) when is_binary(v) or is_integer(v) or is_float(v), do: v
  defp encode_arg(true), do: 1
  defp encode_arg(false), do: 0
  defp encode_arg(v) when is_atom(v), do: Atom.to_string(v)
  defp encode_arg(v) when is_map(v) or is_list(v), do: Jason.encode!(v)
end
