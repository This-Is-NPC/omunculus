defmodule Omunculus.EventCore.StoreTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Omunculus.EventCore.Store

  @original_work_items """
  CREATE TABLE WORK_ITEMS (
    work_item_id TEXT PRIMARY KEY,
    project_id TEXT,
    parent_work_item_id TEXT,
    instruction TEXT NOT NULL,
    status TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 0,
    checkpoint TEXT,
    result TEXT,
    created_at TEXT,
    updated_at TEXT,
    last_sequence INTEGER NOT NULL DEFAULT 0
  )
  """

  @original_archive_runs """
  CREATE TABLE ARCHIVE_RUNS (
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
    started_at TEXT,
    finished_at TEXT,
    last_sequence INTEGER NOT NULL DEFAULT 0
  )
  """

  defp tempfile_path do
    name = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(System.tmp_dir!(), "omunculus-store-test-#{name}.sqlite3")
  end

  defp column_names(conn, table) do
    Store.query(conn, "PRAGMA table_info(#{table})")
    |> Enum.map(fn row -> Enum.at(row, 1) end)
  end

  test "migrates leftover databases from original schema" do
    path = tempfile_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, @original_work_items)
    :ok = Sqlite3.execute(conn, @original_archive_runs)
    :ok = Sqlite3.close(conn)

    assert {:ok, conn} = Store.open(path)
    assert [[4]] = Store.query(conn, "PRAGMA user_version")

    archive_cols = column_names(conn, "ARCHIVE_RUNS")
    assert "outcome" in archive_cols
    assert "reason" in archive_cols
    assert "policy_hash" in archive_cols

    work_item_cols = column_names(conn, "WORK_ITEMS")
    assert "requested_by" in work_item_cols
    assert "awaiting" in work_item_cols
    assert "workspace_id" in work_item_cols

    comment_cols = column_names(conn, "COMMENTS")
    assert "session_id" in comment_cols
    assert "event_id" in comment_cols
    assert "read_at" in comment_cols

    assert Store.query(conn, "SELECT outcome, reason, policy_hash FROM ARCHIVE_RUNS") == []

    Store.close(conn)

    assert {:ok, conn2} = Store.open(path)
    assert [[4]] = Store.query(conn2, "PRAGMA user_version")
    Store.close(conn2)
  end

  test "fresh database gets current schema and user_version 4" do
    path = tempfile_path()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, conn} = Store.open(path)
    assert [[4]] = Store.query(conn, "PRAGMA user_version")

    archive_cols = column_names(conn, "ARCHIVE_RUNS")
    assert "outcome" in archive_cols
    assert "reason" in archive_cols
    assert "policy_hash" in archive_cols

    work_item_cols = column_names(conn, "WORK_ITEMS")
    assert "requested_by" in work_item_cols
    assert "awaiting" in work_item_cols
    assert "workspace_id" in work_item_cols

    assert "read_at" in column_names(conn, "COMMENTS")

    Store.close(conn)
  end

  test ":memory: database gets user_version 4" do
    assert {:ok, conn} = Store.open(":memory:")
    assert [[4]] = Store.query(conn, "PRAGMA user_version")

    archive_cols = column_names(conn, "ARCHIVE_RUNS")
    assert "outcome" in archive_cols
    assert "policy_hash" in archive_cols

    work_item_cols = column_names(conn, "WORK_ITEMS")
    assert "requested_by" in work_item_cols
    assert "awaiting" in work_item_cols
    assert "workspace_id" in work_item_cols

    Store.close(conn)
  end

  test "migrates v1 leftover databases to user_version 4" do
    path = tempfile_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE WORK_ITEMS (
        work_item_id TEXT PRIMARY KEY,
        project_id TEXT,
        parent_work_item_id TEXT,
        instruction TEXT NOT NULL,
        status TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        checkpoint TEXT,
        awaiting TEXT,
        result TEXT,
        created_at TEXT,
        updated_at TEXT,
        last_sequence INTEGER NOT NULL DEFAULT 0
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE ARCHIVE_RUNS (
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
        started_at TEXT,
        finished_at TEXT,
        last_sequence INTEGER NOT NULL DEFAULT 0
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE COMMENTS (
        comment_id TEXT PRIMARY KEY,
        work_item_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        body TEXT,
        created_at TEXT,
        last_sequence INTEGER NOT NULL DEFAULT 0
      )
      """)

    :ok = Sqlite3.execute(conn, "PRAGMA user_version = 1")
    :ok = Sqlite3.close(conn)

    assert {:ok, conn} = Store.open(path)
    assert [[4]] = Store.query(conn, "PRAGMA user_version")
    assert "workspace_id" in column_names(conn, "WORK_ITEMS")
    assert "session_id" in column_names(conn, "COMMENTS")
    assert "event_id" in column_names(conn, "COMMENTS")
    assert "read_at" in column_names(conn, "COMMENTS")

    assert [["SESSION_WORKSPACES"]] =
             Store.query(
               conn,
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'SESSION_WORKSPACES'"
             )

    Store.close(conn)
  end
end
