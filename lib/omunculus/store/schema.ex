defmodule Omunculus.Store.Schema do
  @moduledoc """
  DDL for prompts, events, runs, comments, works, requests, request escalations, interceptions, inbox,
  conversations, memberships and command receipts. It also enforces the
  store rules at the database level: events and escalation links are append only, request options and participant identities are immutable, and the
  system columns — `runs.tools`, `runs.prompt_id`,
  `runs.started_at`, and `created_at` on prompts, comments, works,
  requests and inbox — refuse UPDATE.
  """

  alias Omunculus.Store.Query

  @statements [
    """
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      created_issuer TEXT NOT NULL,
      created_subject TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS project_members (
      issuer TEXT NOT NULL,
      subject TEXT NOT NULL,
      role TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (issuer, subject)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS conversation_members (
      conversation_id TEXT NOT NULL REFERENCES conversations (id),
      issuer TEXT NOT NULL,
      subject TEXT NOT NULL,
      role TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (conversation_id, issuer, subject)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS command_receipts (
      issuer TEXT NOT NULL,
      subject TEXT NOT NULL,
      command_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      result TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (issuer, subject, command_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS prompts (
      id TEXT PRIMARY KEY,
      conversation_id TEXT REFERENCES conversations (id),
      actor_issuer TEXT,
      actor_subject TEXT,
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
      conversation_id TEXT REFERENCES conversations (id),
      actor_kind TEXT CHECK (actor_kind IN ('human', 'agent', 'harness')),
      actor_id TEXT,
      actor_issuer TEXT,
      actor_subject TEXT,
      origin_issuer TEXT,
      origin_subject TEXT,
      prompt_id TEXT REFERENCES prompts (id) DEFERRABLE INITIALLY DEFERRED,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      comment_id TEXT,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      inbox_id TEXT REFERENCES inbox (id) DEFERRABLE INITIALLY DEFERRED,
      released_by TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      body TEXT NOT NULL,
      at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS runs (
      id TEXT PRIMARY KEY,
      conversation_id TEXT REFERENCES conversations (id),
      origin_issuer TEXT,
      origin_subject TEXT,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      prompt_id TEXT REFERENCES prompts (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      agent TEXT NOT NULL,
      depth TEXT NOT NULL,
      via TEXT,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      cause_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      tools TEXT,
      status TEXT NOT NULL CHECK (status IN ('open', 'done')),
      started_at TEXT,
      finished_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS comments (
      id TEXT PRIMARY KEY,
      actor_issuer TEXT,
      actor_subject TEXT,
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      request_id TEXT REFERENCES requests (id) DEFERRABLE INITIALLY DEFERRED,
      inbox_id TEXT REFERENCES inbox (id) DEFERRABLE INITIALLY DEFERRED,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      author TEXT NOT NULL CHECK (author IN ('agent', 'human', 'harness')),
      kind TEXT NOT NULL CHECK (kind IN ('note')),
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      CHECK (work_id IS NOT NULL OR request_id IS NOT NULL OR inbox_id IS NOT NULL)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS works (
      id TEXT PRIMARY KEY,
      conversation_id TEXT REFERENCES conversations (id),
      parent_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      workspace TEXT,
      assignee TEXT,
      title TEXT NOT NULL,
      goal TEXT NOT NULL,
      workflow TEXT,
      stage TEXT,
      state TEXT NOT NULL CHECK (state IN ('open', 'waiting', 'done', 'cancelled')),
      waiting TEXT,
      waiting_for TEXT,
      waiting_from TEXT,
      grants TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS events_conversation_cursor ON events (conversation_id, sequence)",
    "CREATE INDEX IF NOT EXISTS events_memory ON events (sequence) WHERE type = 'memory'",
    "CREATE INDEX IF NOT EXISTS events_jobs ON events (sequence) WHERE type = 'job'",
    "CREATE INDEX IF NOT EXISTS events_job_fires ON events (json_extract(body, '$.id'), sequence) WHERE type = 'job_fire'",
    "CREATE INDEX IF NOT EXISTS events_job_fire_ids ON events (json_extract(body, '$.fire_id'), sequence) WHERE type = 'job_fire'",
    "CREATE INDEX IF NOT EXISTS works_conversation ON works (conversation_id)",
    "CREATE INDEX IF NOT EXISTS runs_cause ON runs (cause_id)",
    """
    CREATE TABLE IF NOT EXISTS requests (
      id TEXT PRIMARY KEY,
      run_id TEXT REFERENCES runs (id) DEFERRABLE INITIALLY DEFERRED,
      requester TEXT NOT NULL CHECK (json_valid(requester)),
      work_id TEXT REFERENCES works (id) DEFERRABLE INITIALLY DEFERRED,
      options TEXT NOT NULL,
      arbiter TEXT NOT NULL CHECK (json_valid(arbiter)),
      status TEXT NOT NULL CHECK (status IN ('pending', 'escalated', 'closed')),
      event_id TEXT REFERENCES events (id) DEFERRABLE INITIALLY DEFERRED,
      created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS request_escalations (
      origin_id TEXT NOT NULL REFERENCES requests (id),
      escalated_id TEXT NOT NULL REFERENCES requests (id),
      part TEXT NOT NULL CHECK (part <> ''),
      event_id TEXT NOT NULL REFERENCES events (id),
      PRIMARY KEY (origin_id, escalated_id),
      CHECK (origin_id <> escalated_id),
      UNIQUE (escalated_id, part)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS interceptions (
      request_id TEXT PRIMARY KEY REFERENCES requests (id),
      rule INTEGER NOT NULL,
      action TEXT NOT NULL,
      summary TEXT NOT NULL,
      target TEXT CHECK (target IS NULL OR json_valid(target)),
      reviewers TEXT NOT NULL CHECK (json_valid(reviewers)),
      step INTEGER NOT NULL,
      passed TEXT NOT NULL CHECK (json_valid(passed)),
      actor TEXT NOT NULL CHECK (json_valid(actor)),
      emit TEXT NOT NULL CHECK (json_valid(emit)),
      next_id TEXT REFERENCES requests (id)
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
    CREATE TRIGGER IF NOT EXISTS requests_options_immutable
    BEFORE UPDATE OF options ON requests
    BEGIN
      SELECT RAISE(ABORT, 'requests.options: immutable');
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
    {"requests", "requester"},
    {"requests", "arbiter"},
    {"inbox", "created_at"}
  ]

  # Each table's definition as sqlite_master keeps it, whitespace collapsed.
  @tables Map.new(
            for "CREATE TABLE IF NOT EXISTS " <> rest <- @statements do
              [name | _] = String.split(rest, " ", parts: 2)
              {name, ("CREATE TABLE " <> rest) |> String.split() |> Enum.join(" ")}
            end
          )

  @spec create(Omunculus.Store.Connection.t()) :: :ok | {:error, term}
  def create(conn) do
    with :ok <- current(conn) do
      statements =
        @statements ++
          Enum.map(@system_columns, &system_column_trigger/1) ++
          Enum.map(~w(UPDATE DELETE), fn operation ->
            "CREATE TRIGGER IF NOT EXISTS request_escalations_no_#{String.downcase(operation)} BEFORE #{operation} ON request_escalations BEGIN SELECT RAISE(ABORT, 'request_escalations: append only'); END"
          end)

      Enum.reduce_while(statements, :ok, fn statement, :ok ->
        case Query.exec(conn, statement) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  # A store holds none of the schema's tables, or all of them as defined here.
  defp current(conn) do
    with {:ok, rows} <-
           Query.all(conn, "SELECT name, sql FROM sqlite_master WHERE type = 'table'") do
      tables =
        for %{name: name, sql: sql} <- rows,
            Map.has_key?(@tables, name),
            into: %{},
            do: {name, sql |> String.split() |> Enum.join(" ")}

      if tables == %{} or tables == @tables,
        do: :ok,
        else: {:error, :store_requires_recreation}
    end
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
