defmodule Omunculus.Store.ActionsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.{Actions, Query}

  @ctx %{run_id: nil, author: "agent"}

  defp count(conn, table) do
    {:ok, %{count: count}} = Query.one(conn, "SELECT COUNT(*) AS count FROM #{table}")
    count
  end

  test "comment on an existing work appends event and comment row", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    run_id = Fixtures.insert(conn, :runs)
    ctx = %{run_id: run_id, author: "human"}

    assert {:ok, [event]} =
             Actions.apply(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}],
               ctx
             )

    assert event.type == "comment"
    assert event.work_id == work_id
    assert event.sequence == 1

    assert {:ok, comment} =
             Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

    assert comment.author == "human"
    assert comment.kind == "note"
    assert comment.event_id == event.id
    assert comment.run_id == run_id
  end

  test "comment on an existing request", %{conn: conn} do
    request_id = Fixtures.insert(conn, :requests)

    assert {:ok, [event]} =
             Actions.apply(
               conn,
               [%{"type" => "comment", "body" => %{"request_id" => request_id, "body" => "hi"}}],
               @ctx
             )

    assert event.type == "comment"
    assert event.request_id == request_id

    assert {:ok, comment} =
             Query.one(conn, "SELECT * FROM comments WHERE request_id = ?", [request_id])

    assert comment.event_id == event.id
  end

  test "comment on an existing inbox entry", %{conn: conn} do
    inbox_id = Fixtures.insert(conn, :inbox)

    assert {:ok, [event]} =
             Actions.apply(
               conn,
               [%{"type" => "comment", "body" => %{"inbox_id" => inbox_id, "body" => "hi"}}],
               @ctx
             )

    assert event.type == "comment"
    assert event.inbox_id == inbox_id

    assert {:ok, comment} =
             Query.one(conn, "SELECT * FROM comments WHERE inbox_id = ?", [inbox_id])

    assert comment.event_id == event.id
  end

  test "comment without text is rejected and writes nothing", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)

    assert {:error, {:comment, :no_body}} =
             Actions.apply(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => work_id}}],
               @ctx
             )

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "comment with no target is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:comment, :no_target}} =
             Actions.apply(conn, [%{"type" => "comment", "body" => %{"body" => "hi"}}], @ctx)

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "comment with a non-existent work id is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:comment, {:missing, :works, "nope"}}} =
             Actions.apply(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "hi"}}],
               @ctx
             )

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "two apply calls sequence events 1 then 2", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    emit = %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}

    assert {:ok, [first]} = Actions.apply(conn, [emit], @ctx)
    assert {:ok, [second]} = Actions.apply(conn, [emit], @ctx)

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "two emits in one apply call sequence 1 and 2 in order", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    request_id = Fixtures.insert(conn, :requests)

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "first"}},
      %{"type" => "comment", "body" => %{"request_id" => request_id, "body" => "second"}}
    ]

    assert {:ok, [first, second]} = Actions.apply(conn, emits, @ctx)

    assert first.sequence == 1
    assert second.sequence == 2
    assert first.work_id == work_id
    assert second.request_id == request_id
    assert count(conn, "events") == 2
    assert count(conn, "comments") == 2
  end

  test "a batch with one invalid emit commits nothing", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "ok"}},
      %{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "bad"}}
    ]

    assert {:error, {:comment, {:missing, :works, "nope"}}} = Actions.apply(conn, emits, @ctx)

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "a catalogue action not implemented yet is refused", %{conn: conn} do
    assert {:error, {:not_yet, "work"}} =
             Actions.apply(conn, [%{"type" => "work", "body" => %{}}], @ctx)

    assert count(conn, "events") == 0
  end

  test "an action outside the catalogue is unknown", %{conn: conn} do
    assert {:error, {:unknown_action, "nope"}} =
             Actions.apply(conn, [%{"type" => "nope", "body" => %{}}], @ctx)

    assert count(conn, "events") == 0
  end
end
