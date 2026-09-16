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

  test "runs.tools, runs.prompt_id and runs.started_at refuse UPDATE", %{conn: conn} do
    id = Fixtures.insert(conn, :runs)

    assert {:error, message} =
             Query.exec(conn, "UPDATE runs SET tools = ? WHERE id = ?", ["[]", id])

    assert message =~ "runs.tools: system column"

    assert {:error, message} =
             Query.exec(conn, "UPDATE runs SET prompt_id = ? WHERE id = ?", ["p1", id])

    assert message =~ "runs.prompt_id: system column"

    assert {:error, message} =
             Query.exec(conn, "UPDATE runs SET started_at = ? WHERE id = ?", ["2026-01-01", id])

    assert message =~ "runs.started_at: system column"

    assert :ok = Query.exec(conn, "UPDATE runs SET status = 'done' WHERE id = ?", [id])
  end

  test "created_at refuses UPDATE on prompts, comments, works, requests and inbox", %{
    conn: conn
  } do
    work_id = Fixtures.insert(conn, :works)

    for {table, attrs} <- [
          prompts: %{},
          comments: %{work_id: work_id},
          works: %{},
          requests: %{},
          inbox: %{}
        ] do
      id = Fixtures.insert(conn, table, attrs)

      assert {:error, message} =
               Query.exec(conn, "UPDATE #{table} SET created_at = ? WHERE id = ?", [
                 "2026-01-01",
                 id
               ])

      assert message =~ "#{table}.created_at: system column"
    end
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
