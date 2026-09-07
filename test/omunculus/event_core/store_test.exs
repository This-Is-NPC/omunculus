defmodule Omunculus.EventCore.StoreTest do
  use ExUnit.Case, async: true

  alias Omunculus.EventCore.Store

  defp tempfile_path do
    name = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(System.tmp_dir!(), "omunculus-store-test-#{name}.sqlite3")
  end

  defp column_names(conn, table) do
    Store.query(conn, "PRAGMA table_info(#{table})")
    |> Enum.map(fn row -> Enum.at(row, 1) end)
  end

  test "fresh database gets current schema" do
    path = tempfile_path()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, conn} = Store.open(path)

    archive_cols = column_names(conn, "ARCHIVE_RUNS")
    assert "outcome" in archive_cols
    assert "reason" in archive_cols
    assert "policy_hash" in archive_cols

    work_item_cols = column_names(conn, "WORK_ITEMS")
    assert "state" in work_item_cols
    assert "status" in work_item_cols
    assert "requested_by" in work_item_cols
    assert "awaiting" in work_item_cols
    assert "workspace_id" in work_item_cols

    assert "read_at" in column_names(conn, "COMMENTS")

    Store.close(conn)
  end

  test ":memory: database gets current schema" do
    assert {:ok, conn} = Store.open(":memory:")

    archive_cols = column_names(conn, "ARCHIVE_RUNS")
    assert "outcome" in archive_cols
    assert "policy_hash" in archive_cols

    work_item_cols = column_names(conn, "WORK_ITEMS")
    assert "state" in work_item_cols
    assert "status" in work_item_cols
    assert "requested_by" in work_item_cols
    assert "awaiting" in work_item_cols
    assert "workspace_id" in work_item_cols

    Store.close(conn)
  end
end
