defmodule Omunculus.Store.ActionsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.Query
  alias Omunculus.Store

  @ctx %{run_id: nil, author: "agent", work_id: nil, agent: "concierge"}
  @call %{name: "t", args: %{}, ok: true, output: ""}

  defp count(conn, table) do
    {:ok, %{count: count}} = Query.one(conn, "SELECT COUNT(*) AS count FROM #{table}")
    count
  end

  defp record_tool(conn, emits, ctx), do: Store.record_tool(conn, nil, @call, emits, ctx)

  test "comment on an existing work appends event and comment row", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    run_id = Fixtures.insert(conn, :runs)
    ctx = %{run_id: run_id, author: "human", work_id: nil, agent: nil}

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}],
               ctx
             )

    assert event.type == "comment"
    assert event.work_id == work_id
    assert event.sequence == 2

    assert {:ok, comment} =
             Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

    assert comment.author == "human"
    assert comment.kind == "note"
    assert comment.event_id == event.id
    assert comment.run_id == run_id
  end

  test "comment on an existing request", %{conn: conn} do
    request_id = Fixtures.insert(conn, :requests)

    assert {:ok, [_tool_event, event]} =
             record_tool(
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

    assert {:ok, [_tool_event, event]} =
             record_tool(
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

  test "comment without text is rejected and writes nothing, including the tool event", %{
    conn: conn
  } do
    work_id = Fixtures.insert(conn, :works)

    assert {:error, {:comment, :no_body}} =
             record_tool(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => work_id}}],
               @ctx
             )

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "comment with no target is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:comment, :no_target}} =
             record_tool(conn, [%{"type" => "comment", "body" => %{"body" => "hi"}}], @ctx)

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "comment with a non-existent work id is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:comment, {:missing, :works, "nope"}}} =
             record_tool(
               conn,
               [%{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "hi"}}],
               @ctx
             )

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "two record_tool calls sequence events 1,2 then 3,4", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    emit = %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}

    assert {:ok, [first_tool, first]} = record_tool(conn, [emit], @ctx)
    assert {:ok, [second_tool, second]} = record_tool(conn, [emit], @ctx)

    assert first_tool.sequence == 1
    assert first.sequence == 2
    assert second_tool.sequence == 3
    assert second.sequence == 4
  end

  test "two emits in one record_tool call sequence 2 and 3 in order", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    request_id = Fixtures.insert(conn, :requests)

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "first"}},
      %{"type" => "comment", "body" => %{"request_id" => request_id, "body" => "second"}}
    ]

    assert {:ok, [tool_event, first, second]} = record_tool(conn, emits, @ctx)

    assert tool_event.sequence == 1
    assert first.sequence == 2
    assert second.sequence == 3
    assert first.work_id == work_id
    assert second.request_id == request_id
    assert count(conn, "events") == 3
    assert count(conn, "comments") == 2
  end

  test "a batch with one invalid emit commits nothing, not even the tool event", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "ok"}},
      %{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "bad"}}
    ]

    assert {:error, {:comment, {:missing, :works, "nope"}}} = record_tool(conn, emits, @ctx)

    assert count(conn, "comments") == 0
    assert count(conn, "events") == 0
  end

  test "a catalogue action not implemented yet is refused and rolls back the tool event", %{
    conn: conn
  } do
    assert {:error, {:not_yet, "request"}} =
             record_tool(conn, [%{"type" => "request", "body" => %{}}], @ctx)

    assert count(conn, "events") == 0
  end

  test "prompt writes a message row and a prompt event", %{conn: conn} do
    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "prompt", "body" => %{"message" => "conte até 5"}}],
               @ctx
             )

    assert event.type == "prompt"
    assert event.run_id == nil

    assert {:ok, prompt} =
             Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [event.prompt_id])

    assert prompt.kind == "message"
    assert prompt.body == "conte até 5"
    assert prompt.run_id == nil
  end

  test "prompt without a message is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:prompt, :no_message}} =
             record_tool(conn, [%{"type" => "prompt", "body" => %{}}], @ctx)

    assert count(conn, "prompts") == 0
    assert count(conn, "events") == 0
  end

  test "prompt with a work_id puts it on the event", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "prompt", "body" => %{"message" => "hi", "work_id" => work_id}}],
               @ctx
             )

    assert event.type == "prompt"
    assert event.work_id == work_id
  end

  test "prompt with a non-existent work_id is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:prompt, {:missing, :works, "nope"}}} =
             record_tool(
               conn,
               [%{"type" => "prompt", "body" => %{"message" => "hi", "work_id" => "nope"}}],
               @ctx
             )

    assert count(conn, "prompts") == 0
    assert count(conn, "events") == 0
  end

  test "an action outside the catalogue is unknown and rolls back the tool event", %{
    conn: conn
  } do
    assert {:error, {:unknown_action, "nope"}} =
             record_tool(conn, [%{"type" => "nope", "body" => %{}}], @ctx)

    assert count(conn, "events") == 0
  end

  test "work creates a row, its event, and links them", %{conn: conn} do
    ctx = %{@ctx | agent: "concierge"}

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "Ship the store"}}],
               ctx
             )

    assert event.type == "work"
    assert event.work_id != nil

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
    assert work.title == "Ship the store"
    assert work.assignee == "concierge"
    assert work.state == "open"
    assert work.parent_id == nil
    assert work.event_id == event.id
  end

  test "work creates a child of an existing parent", %{conn: conn} do
    parent_id = Fixtures.insert(conn, :works)

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "child", "parent_id" => parent_id}}],
               @ctx
             )

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
    assert work.parent_id == parent_id
  end

  test "work with a non-existent parent is rejected and writes nothing", %{conn: conn} do
    assert {:error, {:work, {:missing, :works, "nope"}}} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "child", "parent_id" => "nope"}}],
               @ctx
             )

    assert count(conn, "works") == 0
    assert count(conn, "events") == 0
  end

  test "work without a title is rejected", %{conn: conn} do
    assert {:error, {:work, :no_title}} =
             record_tool(conn, [%{"type" => "work", "body" => %{}}], @ctx)

    assert count(conn, "works") == 0
    assert count(conn, "events") == 0
  end

  test "work update changes the title and appends a second work event", %{conn: conn} do
    work_id = Fixtures.insert(conn, :works, %{title: "old"})

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "new", "work_id" => work_id}}],
               @ctx
             )

    assert event.type == "work"
    assert event.work_id == work_id

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
    assert work.title == "new"
    assert work.updated_at != nil

    assert {:ok, events} = Query.all(conn, "SELECT * FROM events WHERE type = 'work'")
    assert length(events) == 1
  end

  test "work update of a missing work is rejected", %{conn: conn} do
    assert {:error, {:work, {:missing, :works, "nope"}}} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "new", "work_id" => "nope"}}],
               @ctx
             )

    assert count(conn, "events") == 0
  end

  test "creating a work inside a run without one sets runs.work_id", %{conn: conn} do
    run_id = Fixtures.insert(conn, :runs, %{work_id: nil})
    ctx = %{@ctx | run_id: run_id}

    assert {:ok, [_tool_event, event]} =
             record_tool(conn, [%{"type" => "work", "body" => %{"title" => "first"}}], ctx)

    assert {:ok, run} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
    assert run.work_id == event.work_id
  end

  test "a second work in the same run does not overwrite runs.work_id", %{conn: conn} do
    run_id = Fixtures.insert(conn, :runs, %{work_id: nil})
    ctx = %{@ctx | run_id: run_id}

    assert {:ok, [_tool_event, first_event]} =
             record_tool(conn, [%{"type" => "work", "body" => %{"title" => "first"}}], ctx)

    assert {:ok, [_tool_event, _second_event]} =
             record_tool(conn, [%{"type" => "work", "body" => %{"title" => "second"}}], ctx)

    assert {:ok, run} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
    assert run.work_id == first_event.work_id
  end
end
