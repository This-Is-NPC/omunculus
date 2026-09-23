defmodule Omunculus.Store.RunsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.{Query, Runs}

  defp ctx(run_id, overrides \\ %{}) do
    Map.merge(
      %{
        run_id: run_id,
        author: "agent",
        work_id: nil,
        agent: "concierge",
        config: Fixtures.config(),
        groups: %{}
      },
      overrides
    )
  end

  test "begin leaves prompt_id nil until attach_assembled", %{conn: conn} do
    message_id = Fixtures.insert(conn, :prompts, %{kind: "message", body: "count to 5"})
    assert {:ok, run} = Runs.begin(conn, Fixtures.run_params(%{prompt_id: message_id}))
    assert run.prompt_id == nil
    assert run.status == "open"

    assert {:ok, run} = Runs.attach_assembled(conn, run.id, "assembled text")

    assert {:ok, assembled} =
             Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [run.prompt_id])

    assert assembled.kind == "assembled"
    assert assembled.body == "assembled text"
    assert assembled.run_id == run.id
  end

  test "open writes the assembled prompt, the run row and the start-run event", %{conn: conn} do
    message_id = Fixtures.insert(conn, :prompts, %{kind: "message", body: "count to 5"})

    run = Fixtures.open_run(conn, %{prompt_id: message_id})

    assert run.status == "open"
    assert run.depth == "0"
    assert run.agent == "concierge"
    assert Jason.decode!(run.tools) == ["send"]

    assert {:ok, assembled} =
             Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [run.prompt_id])

    assert assembled.kind == "assembled"
    assert assembled.run_id == run.id

    assert {:ok, event} = Query.one(conn, "SELECT * FROM events WHERE id = ?", [run.event_id])
    assert event.type == "start-run"
    assert event.run_id == run.id
    assert event.prompt_id == message_id
    assert Jason.decode!(event.body)["ceiling"]["uncited"] == "askable"
    assert Jason.decode!(event.body)["execution"] == %{"id" => "execution-policy"}

    assert {:ok, message} = Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [message_id])
    assert message.run_id == run.id
  end

  test "open with prompt_id: nil works and leaves start-run without a prompt_id", %{conn: conn} do
    run = Fixtures.open_run(conn)

    assert {:ok, event} = Query.one(conn, "SELECT * FROM events WHERE id = ?", [run.event_id])
    assert event.type == "start-run"
    assert event.prompt_id == nil
  end

  test "record_model appends a model event carrying the run id", %{conn: conn} do
    run = Fixtures.open_run(conn)

    assert {:ok, event} = Runs.record_model(conn, run.id, "thinking...")

    assert event.type == "model"
    assert event.run_id == run.id
    assert event.body == "thinking..."
  end

  test "record_tools appends a tool event carrying the run id and the call", %{conn: conn} do
    run = Fixtures.open_run(conn)
    call = %{name: "send", args: %{"message" => "hi"}, ok: true, output: "done"}

    assert {:ok, [event]} = Runs.record_tools(conn, run.id, [{call, []}], ctx(run.id))

    assert event.type == "tool"
    assert event.run_id == run.id
    assert event.body == Jason.encode!(call)
  end

  test "record_tools stamps the tool event with ctx.work_id", %{conn: conn} do
    run = Fixtures.open_run(conn)
    work_id = Fixtures.insert(conn, :works)
    call = %{name: "send", args: %{}, ok: true, output: "done"}

    assert {:ok, [event]} =
             Runs.record_tools(conn, run.id, [{call, []}], ctx(run.id, %{work_id: work_id}))

    assert event.type == "tool"
    assert event.work_id == work_id
  end

  test "record_tools applies the call's emits in the same transaction", %{conn: conn} do
    run = Fixtures.open_run(conn)
    work_id = Fixtures.insert(conn, :works)
    call = %{name: "comment", args: %{}, ok: true, output: "done"}

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}
    ]

    assert {:ok, [tool_event, comment_event]} =
             Runs.record_tools(conn, run.id, [{call, emits}], ctx(run.id))

    assert tool_event.type == "tool"
    assert comment_event.type == "comment"
    assert comment_event.sequence == tool_event.sequence + 1
  end

  test "record_tools rolls back the tool event when an emit fails", %{conn: conn} do
    run = Fixtures.open_run(conn)
    call = %{name: "comment", args: %{}, ok: true, output: "done"}
    emits = [%{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "hi"}}]

    assert {:error, {:comment, {:missing, :works, "nope"}}} =
             Runs.record_tools(conn, run.id, [{call, emits}], ctx(run.id))

    assert {:ok, events} = Query.all(conn, "SELECT * FROM events WHERE type = 'tool'")
    assert events == []
  end

  test "record_tools rolls back every call when a later call's emit fails", %{conn: conn} do
    run = Fixtures.open_run(conn)
    work_id = Fixtures.insert(conn, :works)
    call = %{name: "comment", args: %{}, ok: true, output: ""}
    good = [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}]
    bad = [%{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "hi"}}]

    assert {:error, {:comment, {:missing, :works, "nope"}}} =
             Runs.record_tools(conn, run.id, [{call, good}, {call, bad}], ctx(run.id))

    assert {:ok, []} = Query.all(conn, "SELECT * FROM events WHERE type IN ('tool', 'comment')")
    assert {:ok, []} = Query.all(conn, "SELECT * FROM comments")
  end

  test "close marks the run done and appends end-run", %{conn: conn} do
    run = Fixtures.open_run(conn)

    assert {:ok, event} = Runs.close(conn, run.id)

    assert event.type == "end-run"
    assert event.run_id == run.id

    assert {:ok, closed} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run.id])
    assert closed.status == "done"
    assert closed.finished_at != nil
  end

  test "closing a run that is not open fails and writes nothing", %{conn: conn} do
    run = Fixtures.open_run(conn)
    {:ok, _event} = Runs.close(conn, run.id)

    assert {:error, {:run, :not_open}} = Runs.close(conn, run.id)

    assert {:ok, events} = Query.all(conn, "SELECT * FROM events WHERE type = 'end-run'")
    assert length(events) == 1
  end

  test "closing an unknown run fails", %{conn: conn} do
    assert {:error, {:run, :not_open}} = Runs.close(conn, "nope")
  end

  test "replay of the run lists start-run, model, tool, end-run in sequence", %{conn: conn} do
    run = Fixtures.open_run(conn)
    {:ok, _} = Runs.record_model(conn, run.id, "thinking...")

    {:ok, _} =
      Runs.record_tools(
        conn,
        run.id,
        [{%{name: "send", args: %{}, ok: true, output: "ok"}, []}],
        ctx(run.id)
      )

    {:ok, _} = Runs.close(conn, run.id)

    assert {:ok, events} = Omunculus.Store.replay(conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "model", "tool", "end-run"]
  end

  defp unreported(conn, run, max_retries),
    do:
      Runs.unreported(
        conn,
        run,
        max_retries,
        &"stopped after #{&1}",
        &"#{&1} #{&2} #{Enum.join(&3, " ")}"
      )

  test "unreported retries a work while its runs without end are within max_retries",
       %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    run = Fixtures.open_run(conn, %{work_id: work_id})
    {:ok, _} = Runs.close(conn, run.id)

    assert {:ok, :retry} = unreported(conn, run, 1)

    Query.exec(conn, "UPDATE works SET state = 'done' WHERE id = ?", [work_id])
    assert {:ok, :none} = unreported(conn, run, 1)
  end

  test "unreported past max_retries breaks a child: comments the text, parks it and wakes its parent",
       %{conn: conn} do
    parent_id = Fixtures.insert(conn, :works, %{state: "waiting", waiting: "child"})
    child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
    run = Fixtures.open_run(conn, %{work_id: child_id})
    {:ok, _} = Runs.close(conn, run.id)

    assert {:ok, {:stopped, [event]}} = unreported(conn, run, 0)

    assert event.type == "break"
    assert event.run_id == run.id
    assert Jason.decode!(event.body) == %{"body" => "stopped after 1", "parent_id" => parent_id}

    assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
    assert child.state == "waiting"
    assert child.waiting_from == "concierge"

    assert {:ok, [comment]} =
             Query.all(conn, "SELECT * FROM comments WHERE work_id = ?", [child_id])

    assert comment.body == "stopped after 1"
    assert comment.run_id == run.id

    assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
    assert parent.state == "open"
  end

  test "unreported past max_retries asks the human about a root, naming the request in the inbox",
       %{conn: conn} do
    work_id = Fixtures.insert(conn, :works)
    run = Fixtures.open_run(conn, %{work_id: work_id})
    {:ok, _} = Runs.close(conn, run.id)

    assert {:ok, {:stopped, [request, notify]}} = unreported(conn, run, 0)
    assert request.type == "request"
    assert notify.type == "notify"

    assert {:ok, [comment]} =
             Query.all(conn, "SELECT * FROM comments WHERE inbox_id IS NOT NULL")

    assert comment.body == "#{request.request_id} stopped after 1 cancel retry"
  end

  test "begin refuses a cancelled work, and a work's own run on a work not open",
       %{conn: conn} do
    waiting = Fixtures.insert(conn, :works, %{state: "waiting", waiting: "child"})
    cancelled = Fixtures.insert(conn, :works, %{state: "cancelled"})

    assert {:error, {:not_open, ^waiting}} =
             Runs.begin(conn, Fixtures.run_params(%{work_id: waiting, own: true}))

    assert {:ok, _named} = Runs.begin(conn, Fixtures.run_params(%{work_id: waiting}))

    assert {:error, {:cancelled, ^cancelled}} =
             Runs.begin(conn, Fixtures.run_params(%{work_id: cancelled}))
  end
end
