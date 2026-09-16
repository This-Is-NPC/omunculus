defmodule Omunculus.Store.SchemaTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.Query

  test "creates exactly the seven tables", %{conn: conn} do
    {:ok, rows} =
      Query.all(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )

    assert Enum.map(rows, & &1.name) == ~w(comments events inbox prompts requests runs works)
  end

  test "foreign keys are enforced", %{conn: conn} do
    assert {:ok, %{foreign_keys: 1}} = Query.one(conn, "PRAGMA foreign_keys")
  end

  test "events are append only", %{conn: conn} do
    id = Fixtures.insert(conn, :events, %{sequence: 1})

    assert {:error, message} =
             Query.exec(conn, "UPDATE events SET type = 'model' WHERE id = ?", [id])

    assert message =~ "append only"

    assert {:error, message} = Query.exec(conn, "DELETE FROM events WHERE id = ?", [id])
    assert message =~ "append only"
  end

  test "requests.ask is immutable, other columns update", %{conn: conn} do
    id = Fixtures.insert(conn, :requests)

    assert {:error, message} =
             Query.exec(conn, "UPDATE requests SET ask = ? WHERE id = ?", ["{}", id])

    assert message =~ "immutable"

    assert :ok = Query.exec(conn, "UPDATE requests SET status = ? WHERE id = ?", ["closed", id])
  end

  test "a comment referenced by an event can be deleted", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    comment_id = Fixtures.insert(conn, :comments, %{work_id: work_id})
    Fixtures.insert(conn, :events, %{sequence: 1, comment_id: comment_id})

    assert :ok = Query.exec(conn, "DELETE FROM comments WHERE id = ?", [comment_id])
  end

  test "comments with no target are rejected", %{conn: conn} do
    assert {:error, _reason} =
             Query.exec(
               conn,
               "INSERT INTO comments (id, author, kind, body, created_at) VALUES (?, ?, ?, ?, ?)",
               ["c1", "agent", "note", "hi", "2026-09-15T00:00:00Z"]
             )
  end
end
