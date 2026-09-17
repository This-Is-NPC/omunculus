defmodule Omunculus.Store.Schema do
  @moduledoc """
  DDL for the seven tables of spec §4 — prompts, events, runs, comments,
  works, requests, inbox — plus the store rules enforced at the database
  level: events are append only, requests.ask is immutable, and the
  system columns of spec §8.3 — `runs.tools`, `runs.prompt_id`,
  `runs.started_at`, and `created_at` on prompts, comments, works,
  requests and inbox — refuse UPDATE.
  """

  alias Omunculus.Store.Query

  @statements [
    """
    CREATE TABLE IF NOT EXISTS prompts (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('message', 'assembled')),
      body TEXT NOT NULL,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY,
      sequence INTEGER NOT NULL UNIQUE,
      type TEXT NOT NULL,
      prompt_id TEXT REFERENCES prompts (id) DEFERRABLE INITIALLY DEFERRED,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      comment_id TEXT,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      inbox_id TEXT REFERENCES inbox (id) DEFERRABLE INITIALLY DEFERRED,
      body TEXT NOT NULL,
      at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS runs (
      id TEXT PRIMARY KEY,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      prompt_id TEXT REFERENCES prompts (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      agent TEXT NOT NULL,
      depth TEXT NOT NULL,
      via TEXT,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      tools TEXT,
      status TEXT NOT NULL CHECK (status IN ('open', 'done')),
      started_at TEXT,
      finished_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS comments (
      id TEXT PRIMARY KEY,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      inbox_id TEXT REFERENCES inbox (id) DEFERRABLE INITIALLY DEFERRED,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      author TEXT NOT NULL CHECK (author IN ('agent', 'human')),
      kind TEXT NOT NULL CHECK (kind IN ('note')),
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      CHECK (work_id IS NOT NULL OR request_id IS NOT NULL OR inbox_id IS NOT NULL)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS works (
      id TEXT PRIMARY KEY,
      parent_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      workspace TEXT,
      assignee TEXT,
      title TEXT NOT NULL,
      stage TEXT,
      state TEXT NOT NULL CHECK (state IN ('open', 'waiting', 'done')),
      waiting TEXT,
      waiting_for TEXT,
      waiting_from TEXT,
      grants TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS requests (
      id TEXT PRIMARY KEY,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      agent TEXT NOT NULL,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      ask TEXT,
      arbiter TEXT,
      status TEXT NOT NULL CHECK (status IN ('waiting_human', 'waiting_agent', 'closed')),
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS inbox (
      id TEXT PRIMARY KEY,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      agent TEXT NOT NULL,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      read_at TEXT,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TRIGGER IF NOT EXISTS events_no_update
    BEFORE UPDATE ON events
    BEGIN
      SELECT RAISE(ABORT, 'events: append only');
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS events_no_delete
    BEFORE DELETE ON events
    BEGIN
      SELECT RAISE(ABORT, 'events: append only');
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS requests_ask_immutable
    BEFORE UPDATE OF ask ON requests
    BEGIN
      SELECT RAISE(ABORT, 'requests.ask: immutable');
    END
    """
  ]

  @system_columns [
    {"runs", "tools"},
    {"runs", "prompt_id"},
    {"runs", "started_at"},
    {"prompts", "created_at"},
    {"comments", "created_at"},
    {"works", "created_at"},
    {"requests", "created_at"},
    {"inbox", "created_at"}
  ]

  @spec create(Exqlite.Sqlite3.db()) :: :ok | {:error, term}
  def create(conn) do
    statements = @statements ++ Enum.map(@system_columns, &system_column_trigger/1)

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case Query.exec(conn, statement) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp system_column_trigger({"runs", "prompt_id"}) do
    """
    CREATE TRIGGER IF NOT EXISTS runs_prompt_id_system
    BEFORE UPDATE OF prompt_id ON runs
    WHEN OLD.prompt_id IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'runs.prompt_id: system column');
    END
    """
  end

  defp system_column_trigger({table, column}) do
    """
    CREATE TRIGGER IF NOT EXISTS #{table}_#{column}_system
    BEFORE UPDATE OF #{column} ON #{table}
    BEGIN
      SELECT RAISE(ABORT, '#{table}.#{column}: system column');
    END
    """
  end
end
