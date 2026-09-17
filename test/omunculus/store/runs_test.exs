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

  defp open_params(prompt_id) do
    %{
      prompt_id: prompt_id,
      agent: "concierge",
      depth: 0,
      ceiling: %{have: ["send"], askable: [], sealed: [], blocked: [], uncited: "askable"},
      execution: %{"id" => "execution-policy"},
      assembled: "agent text + message",
      work_id: nil,
      via: nil,
      request_id: nil
    }
  end

  test "open writes the assembled prompt, the run row and the start-run event", %{conn: conn} do
    message_id = Fixtures.insert(conn, :prompts, %{kind: "message", body: "count to 5"})

    assert {:ok, run} = Runs.open(conn, open_params(message_id))

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
    assert {:ok, run} = Runs.open(conn, open_params(nil))

    assert {:ok, event} = Query.one(conn, "SELECT * FROM events WHERE id = ?", [run.event_id])
    assert event.type == "start-run"
    assert event.prompt_id == nil
  end

  test "record_model appends a model event carrying the run id", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))

    assert {:ok, event} = Runs.record_model(conn, run.id, "thinking...")

    assert event.type == "model"
    assert event.run_id == run.id
    assert event.body == "thinking..."
  end

  test "record_tool appends a tool event carrying the run id and the call", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    call = %{name: "send", args: %{"message" => "hi"}, ok: true, output: "done"}

    assert {:ok, [event]} = Runs.record_tool(conn, run.id, call, [], ctx(run.id))

    assert event.type == "tool"
    assert event.run_id == run.id
    assert event.body == Jason.encode!(call)
  end

  test "record_tool stamps the tool event with ctx.work_id", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    work_id = Fixtures.insert(conn, :works)
    call = %{name: "send", args: %{}, ok: true, output: "done"}

    assert {:ok, [event]} =
             Runs.record_tool(conn, run.id, call, [], ctx(run.id, %{work_id: work_id}))

    assert event.type == "tool"
    assert event.work_id == work_id
  end

  test "record_tool applies the call's emits in the same transaction", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    work_id = Fixtures.insert(conn, :works)
    call = %{name: "comment", args: %{}, ok: true, output: "done"}

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}
    ]

    assert {:ok, [tool_event, comment_event]} =
             Runs.record_tool(conn, run.id, call, emits, ctx(run.id))

    assert tool_event.type == "tool"
    assert comment_event.type == "comment"
    assert comment_event.sequence == tool_event.sequence + 1
  end

  test "record_tool rolls back the tool event when an emit fails", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    call = %{name: "comment", args: %{}, ok: true, output: "done"}
    emits = [%{"type" => "comment", "body" => %{"work_id" => "nope", "body" => "hi"}}]

    assert {:error, {:comment, {:missing, :works, "nope"}}} =
             Runs.record_tool(conn, run.id, call, emits, ctx(run.id))

    assert {:ok, events} = Query.all(conn, "SELECT * FROM events WHERE type = 'tool'")
    assert events == []
  end

  test "close marks the run done and appends end-run", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))

    assert {:ok, event} = Runs.close(conn, run.id)

    assert event.type == "end-run"
    assert event.run_id == run.id

    assert {:ok, closed} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run.id])
    assert closed.status == "done"
    assert closed.finished_at != nil
  end

  test "closing a run that is not open fails and writes nothing", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    {:ok, _event} = Runs.close(conn, run.id)

    assert {:error, {:run, :not_open}} = Runs.close(conn, run.id)

    assert {:ok, events} = Query.all(conn, "SELECT * FROM events WHERE type = 'end-run'")
    assert length(events) == 1
  end

  test "closing an unknown run fails", %{conn: conn} do
    assert {:error, {:run, :not_open}} = Runs.close(conn, "nope")
  end

  test "replay of the run lists start-run, model, tool, end-run in sequence", %{conn: conn} do
    {:ok, run} = Runs.open(conn, open_params(nil))
    {:ok, _} = Runs.record_model(conn, run.id, "thinking...")

    {:ok, _} =
      Runs.record_tool(
        conn,
        run.id,
        %{name: "send", args: %{}, ok: true, output: "ok"},
        [],
        ctx(run.id)
      )

    {:ok, _} = Runs.close(conn, run.id)

    assert {:ok, events} = Omunculus.Store.replay(conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ["start-run", "model", "tool", "end-run"]
  end
end
