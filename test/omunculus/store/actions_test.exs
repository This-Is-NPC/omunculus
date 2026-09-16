defmodule Omunculus.Store.ActionsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.Query
  alias Omunculus.Store

  @ctx %{
    run_id: nil,
    author: "agent",
    work_id: nil,
    agent: "concierge",
    config: Fixtures.config(),
    groups: %{}
  }
  @call %{name: "t", args: %{}, ok: true, output: ""}

  @ceiling %{
    have: ["comment"],
    askable: ["write"],
    sealed: ["deploy"],
    blocked: ["delete"],
    uncited: "askable"
  }

  defp count(conn, table) do
    {:ok, %{count: count}} = Query.one(conn, "SELECT COUNT(*) AS count FROM #{table}")
    count
  end

  defp record_tool(conn, emits, ctx), do: Store.record_tool(conn, nil, @call, emits, ctx)

  defp seed_comment(conn, target, sequence, at, body \\ "note") do
    comment_id =
      Fixtures.insert(conn, :comments, Map.merge(target, %{body: body, created_at: at}))

    Fixtures.insert(
      conn,
      :events,
      Map.merge(target, %{type: "comment", comment_id: comment_id, sequence: sequence, at: at})
    )

    comment_id
  end

  defp open_run(conn, ceiling) do
    params = %{
      prompt_id: nil,
      agent: "concierge",
      depth: 0,
      ceiling: ceiling,
      assembled: "assembled",
      work_id: nil,
      via: nil,
      request_id: nil
    }

    {:ok, run} = Store.open_run(conn, params)
    run
  end

  defp request_ctx(run, work_id \\ nil, config \\ @ctx.config) do
    %{
      run_id: run.id,
      author: "agent",
      work_id: work_id,
      agent: run.agent,
      config: config,
      groups: %{}
    }
  end

  defp request_emit(kind, name, reason) do
    %{"type" => "request", "body" => %{"kind" => kind, "name" => name, "reason" => reason}}
  end

  defp open_request(conn, ceiling, work_id) do
    run = open_run(conn, ceiling)

    {:ok, [_tool_event, event]} =
      record_tool(
        conn,
        [request_emit("tool", "write", "preciso gravar")],
        request_ctx(run, work_id)
      )

    {run, event.request_id}
  end

  defp delivery_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"

    [agents.worker]
    depth = 1
    text = "worker"

    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "concierge" },
      { name = "review", agent = "worker" },
    ]

    [policy]
    workflow = "delivery"
    """
  end

  defp depth1_workflow_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"

    [agents.worker]
    depth = 1
    text = "worker"

    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "worker" },
    ]

    [policy.depth.1]
    workflow = "delivery"
    """
  end

  defp no_worker_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"
    """
  end

  defp grant_write_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"
    granted = ["write"]

    [agents.worker]
    depth = 1
    text = "worker"
    """
  end

  defp deny_write_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"
    deny = ["write"]

    [agents.worker]
    depth = 1
    text = "worker"
    """
  end

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

  test "comment on an existing inbox entry writes no request", %{conn: conn} do
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
    assert count(conn, "requests") == 0
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

  test "work is rejected when the body carries stage, agent or model", %{conn: conn} do
    assert {:error, {:work, {:forbidden, "stage"}}} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "x", "stage" => "review"}}],
               @ctx
             )

    assert {:error, {:work, {:forbidden, "agent"}}} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "x", "agent" => "worker"}}],
               @ctx
             )

    assert count(conn, "works") == 0
  end

  test "work with workflow on sets the first stage and its agent", %{conn: conn} do
    ctx = %{@ctx | config: Fixtures.config(delivery_toml())}

    assert {:ok, [_tool_event, event]} =
             record_tool(conn, [%{"type" => "work", "body" => %{"title" => "Ship it"}}], ctx)

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
    assert work.stage == "to_do"
    assert work.assignee == "concierge"
  end

  test "a child work picks up a workflow set only at its depth", %{conn: conn} do
    ctx = %{@ctx | config: Fixtures.config(depth1_workflow_toml())}
    parent_id = Fixtures.insert(conn, :works)

    assert {:ok, [_tool_event, event]} =
             record_tool(
               conn,
               [%{"type" => "work", "body" => %{"title" => "child", "parent_id" => parent_id}}],
               ctx
             )

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
    assert work.stage == "to_do"
    assert work.assignee == "worker"
  end

  describe "continue action" do
    test "workflow off is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: nil})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id}

      assert {:error, {:continue, :workflow_off}} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)
    end

    test "moves to the next stage and updates the assignee", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "to_do", assignee: "concierge"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert event.type == "continue"
      assert Jason.decode!(event.body) == %{"from" => "to_do", "to" => "review"}

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.stage == "review"
      assert work.assignee == "worker"
      assert work.state == "open"
    end

    test "the last stage closes the work without a parent to reopen", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "review"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert Jason.decode!(event.body) == %{"from" => "review", "to" => nil, "parent_id" => nil}

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "done"
    end

    test "the last stage reopens a parent waiting on this child", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{state: "waiting", waiting: "child"})
      child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, stage: "review"})

      :ok =
        Query.exec(conn, "UPDATE works SET waiting_for = ? WHERE id = ?", [child_id, parent_id])

      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: child_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert Jason.decode!(event.body)["parent_id"] == parent_id

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert parent.state == "open"
      assert parent.waiting == nil
    end

    test "an unknown stage is off_sequence", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "ghost"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:error, {:continue, :off_sequence}} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)
    end

    test "no work is rejected", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: nil, config: Fixtures.config(delivery_toml())}

      assert {:error, {:continue, :no_work}} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)
    end

    test "a body naming the stage is forbidden", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "to_do"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:error, {:continue, {:forbidden, "stage"}}} =
               record_tool(
                 conn,
                 [%{"type" => "continue", "body" => %{"stage" => "review"}}],
                 ctx
               )
    end
  end

  describe "break action" do
    test "workflow off is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: nil})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id}

      assert {:error, {:break, :workflow_off}} =
               record_tool(
                 conn,
                 [%{"type" => "break", "body" => %{"body" => "preciso pausar"}}],
                 ctx
               )
    end

    test "parks the work with a comment and leaves the stage untouched", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "to_do", state: "open"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "break", "body" => %{"body" => "preciso pausar"}}],
                 ctx
               )

      assert event.type == "break"
      assert event.work_id == work_id
      assert event.comment_id != nil

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

      assert comment.body == "preciso pausar"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.stage == "to_do"
      assert work.waiting == nil
      assert work.waiting_from == "concierge"
    end

    test "no body is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{stage: "to_do"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:error, {:break, :no_body}} =
               record_tool(conn, [%{"type" => "break", "body" => %{}}], ctx)
    end

    test "no work is rejected", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: nil, config: Fixtures.config(delivery_toml())}

      assert {:error, {:break, :no_work}} =
               record_tool(
                 conn,
                 [%{"type" => "break", "body" => %{"body" => "x"}}],
                 ctx
               )
    end
  end

  describe "delegate action" do
    test "creates a child work, comments it, and parks the parent", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "delegate",
                     "body" => %{"title" => "Sub task", "body" => "faça isso"}
                   }
                 ],
                 ctx
               )

      assert event.type == "delegate"
      assert event.work_id != nil
      assert event.comment_id != nil

      child_id = event.work_id

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
      assert child.parent_id == parent_id
      assert child.title == "Sub task"
      assert child.state == "open"
      assert child.assignee == "worker"

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [child_id])

      assert comment.body == "faça isso"

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert parent.state == "waiting"
      assert parent.waiting == "child"
      assert parent.waiting_for == child_id
      assert parent.waiting_from == "concierge"

      assert Jason.decode!(event.body) == %{
               "title" => "Sub task",
               "body" => "faça isso",
               "parent_id" => parent_id
             }
    end

    test "the child's assignee comes from the workflow's first step when it is on", %{
      conn: conn
    } do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(delivery_toml())
      }

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "body" => "b"}}],
                 ctx
               )

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert child.stage == "to_do"
      assert child.assignee == "concierge"
    end

    test "no work is rejected", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: nil}

      assert {:error, {:delegate, :no_work}} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "body" => "b"}}],
                 ctx
               )
    end

    test "no agent at the child's depth is an error", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(no_worker_toml())
      }

      assert {:error, {:delegate, {:no_agent_at_depth, 1}}} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "body" => "b"}}],
                 ctx
               )
    end

    test "no title is rejected", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:error, {:delegate, :no_title}} =
               record_tool(conn, [%{"type" => "delegate", "body" => %{"body" => "b"}}], ctx)
    end

    test "no body is rejected", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:error, {:delegate, :no_body}} =
               record_tool(conn, [%{"type" => "delegate", "body" => %{"title" => "t"}}], ctx)
    end
  end

  describe "finish_work" do
    test "marks the work done and reopens a parent waiting on it", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{state: "waiting", waiting: "child"})
      child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, state: "open"})

      :ok =
        Query.exec(conn, "UPDATE works SET waiting_for = ? WHERE id = ?", [child_id, parent_id])

      assert {:ok, event} = Store.finish_work(conn, child_id, nil)

      assert event.type == "work"
      assert event.work_id == child_id
      assert Jason.decode!(event.body) == %{"state" => "done", "parent_id" => parent_id}

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
      assert child.state == "done"

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert parent.state == "open"
      assert parent.waiting == nil
    end

    test "a root work with no parent finishes with a nil parent_id", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, event} = Store.finish_work(conn, work_id, nil)
      assert Jason.decode!(event.body) == %{"state" => "done", "parent_id" => nil}
    end
  end

  describe "request action" do
    test "have does not open a request, emits only the tool event", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:ok, [_tool_event]} =
               record_tool(conn, [request_emit("tool", "comment", "why")], request_ctx(run))

      assert count(conn, "requests") == 0
      assert count(conn, "events") == 2
    end

    test "blocked appends a deny event and opens no request", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [request_emit("tool", "delete", "why")], request_ctx(run))

      assert event.type == "deny"

      assert Jason.decode!(event.body) == %{
               "kind" => "tool",
               "name" => "delete",
               "reason" => "why"
             }

      assert count(conn, "requests") == 0
    end

    test "askable opens a request with a comment and puts the linked work in waiting", %{
      conn: conn
    } do
      run = open_run(conn, @ceiling)
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [request_emit("tool", "write", "preciso gravar")],
                 request_ctx(run, work_id)
               )

      assert event.type == "request"
      assert event.request_id != nil
      assert event.comment_id != nil

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "human"
      assert request.status == "waiting_human"
      assert request.agent == run.agent
      assert request.work_id == work_id
      assert Jason.decode!(request.ask) == %{"kind" => "tool", "name" => "write"}

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE request_id = ?", [event.request_id])

      assert comment.body == "preciso gravar"
      assert comment.event_id == event.id

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.waiting == "access"
      assert work.waiting_for == "write"
      assert work.waiting_from == run.agent
    end

    test "sealed opens a request the same way as askable", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [request_emit("tool", "deploy", "why")], request_ctx(run))

      assert event.type == "request"

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.status == "waiting_human"
    end

    test "a name in no list follows the ceiling's uncited class", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [request_emit("directory", "./secrets", "ler as chaves")],
                 request_ctx(run)
               )

      assert event.type == "request"
    end

    test "an empty kind is rejected and writes nothing", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:error, {:request, {:invalid, :kind}}} =
               record_tool(conn, [request_emit("", "write", "why")], request_ctx(run))

      assert count(conn, "events") == 1
    end

    test "a custom kind opens a request classified by name, not kind", %{conn: conn} do
      run = open_run(conn, @ceiling)
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [request_emit("secret", "vault", "preciso do segredo")],
                 request_ctx(run, work_id)
               )

      assert event.type == "request"

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert Jason.decode!(request.ask) == %{"kind" => "secret", "name" => "vault"}
    end

    test "a missing name is rejected and writes nothing", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:error, {:request, :no_name}} =
               record_tool(
                 conn,
                 [%{"type" => "request", "body" => %{"kind" => "tool", "reason" => "why"}}],
                 request_ctx(run)
               )

      assert count(conn, "events") == 1
    end

    test "a missing reason is rejected and writes nothing", %{conn: conn} do
      run = open_run(conn, @ceiling)

      assert {:error, {:request, :no_reason}} =
               record_tool(
                 conn,
                 [%{"type" => "request", "body" => %{"kind" => "tool", "name" => "write"}}],
                 request_ctx(run)
               )

      assert count(conn, "events") == 1
    end

    test "no run is rejected and writes nothing", %{conn: conn} do
      assert {:error, {:request, :no_run}} =
               record_tool(conn, [request_emit("tool", "write", "why")], @ctx)

      assert count(conn, "events") == 0
    end

    test "a request without a linked work leaves work_id nil and touches no work", %{
      conn: conn
    } do
      run = open_run(conn, @ceiling)

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [request_emit("tool", "write", "why")], request_ctx(run))

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.work_id == nil
      assert count(conn, "works") == 0
    end

    test "askable from a child whose parent's agent has authority routes to that agent", %{
      conn: conn
    } do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = open_run(conn, @ceiling)
      ctx = request_ctx(run, work_id, Fixtures.config(grant_write_toml()))

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [request_emit("tool", "write", "preciso gravar")], ctx)

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "concierge"
      assert request.status == "waiting_agent"

      body = Jason.decode!(event.body)
      assert body["arbiter"] == "concierge"
      assert body["arbiter_work_id"] == parent_id
    end

    test "askable from a child whose parent's agent lacks authority falls back to human", %{
      conn: conn
    } do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = open_run(conn, @ceiling)
      ctx = request_ctx(run, work_id, Fixtures.config(deny_write_toml()))

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [request_emit("tool", "write", "preciso gravar")], ctx)

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "human"
      assert request.status == "waiting_human"
      refute Map.has_key?(Jason.decode!(event.body), "arbiter")
    end
  end

  describe "reply action" do
    test "grant temporary on a request with a work adds the name to works.grants and reopens it",
         %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, reply_event, grant_event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "grant",
                       "body" => "ok, pode gravar"
                     }
                   }
                 ],
                 ctx
               )

      assert reply_event.type == "reply"
      assert grant_event.type == "grant"

      body = Jason.decode!(grant_event.body)
      assert body["name"] == "write"
      assert body["kind"] == "tool"
      assert body["agent"] == run.agent
      assert body["depth"] == 0
      assert body["scope"] == nil

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "closed"

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE request_id = ? AND event_id = ?", [
                 request_id,
                 reply_event.id
               ])

      assert comment.body == "ok, pode gravar"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["write"]
      assert work.state == "open"
      assert work.waiting == nil
    end

    test "granting a closed request is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      reply_emit = %{
        "type" => "reply",
        "body" => %{"request_id" => request_id, "decision" => "grant", "body" => "ok"}
      }

      assert {:ok, _events} = record_tool(conn, [reply_emit], ctx)
      assert {:error, {:reply, :closed}} = record_tool(conn, [reply_emit], ctx)
    end

    test "granting with a scope writes the grant event but does not touch works.grants", %{
      conn: conn
    } do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, _reply_event, grant_event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "grant",
                       "body" => "ok, mudo o teto",
                       "scope" => "agent"
                     }
                   }
                 ],
                 ctx
               )

      assert Jason.decode!(grant_event.body)["scope"] == "agent"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.grants == nil
      assert work.state == "open"
    end

    test "granting a request with no linked work only writes the grant event", %{conn: conn} do
      {run, request_id} = open_request(conn, @ceiling, nil)
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, _reply_event, grant_event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "grant",
                       "body" => "ok"
                     }
                   }
                 ],
                 ctx
               )

      assert grant_event.type == "grant"
      assert count(conn, "works") == 0
    end

    test "deny reopens the linked work and writes a deny event", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, _reply_event, deny_event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "deny",
                       "body" => "não pode"
                     }
                   }
                 ],
                 ctx
               )

      assert deny_event.type == "deny"
      assert deny_event.request_id == request_id
      assert Jason.decode!(deny_event.body) == %{"kind" => "tool", "name" => "write"}

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"
      assert work.waiting == nil
    end

    test "a missing request is rejected", %{conn: conn} do
      assert {:error, {:reply, {:missing, :requests, "nope"}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{"request_id" => "nope", "decision" => "grant", "body" => "ok"}
                   }
                 ],
                 @ctx
               )
    end

    test "an invalid decision is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:error, {:reply, {:invalid, :decision}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "maybe",
                       "body" => "ok"
                     }
                   }
                 ],
                 ctx
               )
    end

    test "an empty reply body is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:error, {:reply, :no_body}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{"request_id" => request_id, "decision" => "grant", "body" => ""}
                   }
                 ],
                 ctx
               )
    end

    test "an invalid scope is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      ctx = request_ctx(run)

      assert {:error, {:reply, {:invalid, :scope}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "reply",
                     "body" => %{
                       "request_id" => request_id,
                       "decision" => "grant",
                       "body" => "ok",
                       "scope" => "workspace"
                     }
                   }
                 ],
                 ctx
               )
    end
  end

  describe "notify action" do
    test "inside a run on a work appends inbox, comment, and event; run and work are untouched",
         %{conn: conn} do
      run = open_run(conn, @ceiling)
      work_id = Fixtures.insert(conn, :works, %{state: "open"})
      ctx = request_ctx(run, work_id)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "notify", "body" => %{"body" => "preciso avisar"}}],
                 ctx
               )

      assert event.type == "notify"
      assert event.work_id == work_id
      assert event.inbox_id != nil
      assert event.comment_id != nil

      assert {:ok, inbox} = Query.one(conn, "SELECT * FROM inbox WHERE id = ?", [event.inbox_id])
      assert inbox.agent == run.agent
      assert inbox.work_id == work_id
      assert inbox.read_at == nil
      assert inbox.event_id == event.id

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE inbox_id = ?", [event.inbox_id])

      assert comment.body == "preciso avisar"
      assert comment.event_id == event.id

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"
      assert work.waiting == nil

      assert {:ok, run_row} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run.id])
      assert run_row.status == "open"
    end

    test "without a work leaves inbox.work_id nil", %{conn: conn} do
      run = open_run(conn, @ceiling)
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "notify", "body" => %{"body" => "aviso solto"}}],
                 ctx
               )

      assert {:ok, inbox} = Query.one(conn, "SELECT * FROM inbox WHERE id = ?", [event.inbox_id])
      assert inbox.work_id == nil
    end

    test "an explicit unknown work_id is rejected and writes nothing", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id}

      assert {:error, {:notify, {:missing, :works, "nope"}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "notify",
                     "body" => %{"body" => "aviso", "work_id" => "nope"}
                   }
                 ],
                 ctx
               )

      assert count(conn, "inbox") == 0
      assert count(conn, "events") == 0
    end

    test "no body is rejected", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id}

      assert {:error, {:notify, :no_body}} =
               record_tool(conn, [%{"type" => "notify", "body" => %{}}], ctx)

      assert count(conn, "inbox") == 0
      assert count(conn, "events") == 0
    end

    test "no run is rejected", %{conn: conn} do
      assert {:error, {:notify, :no_run}} =
               record_tool(
                 conn,
                 [%{"type" => "notify", "body" => %{"body" => "aviso"}}],
                 @ctx
               )

      assert count(conn, "inbox") == 0
      assert count(conn, "events") == 0
    end
  end

  describe "inbox.read action" do
    test "marks read_at and appends an event", %{conn: conn} do
      inbox_id = Fixtures.insert(conn, :inbox)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "inbox.read", "body" => %{"inbox_id" => inbox_id}}],
                 ctx
               )

      assert event.type == "inbox.read"
      assert event.inbox_id == inbox_id
      assert event.run_id == run_id

      assert {:ok, inbox} = Query.one(conn, "SELECT * FROM inbox WHERE id = ?", [inbox_id])
      assert inbox.read_at != nil
    end

    test "reading twice keeps the first read_at", %{conn: conn} do
      inbox_id = Fixtures.insert(conn, :inbox)
      emit = [%{"type" => "inbox.read", "body" => %{"inbox_id" => inbox_id}}]

      assert {:ok, _} = record_tool(conn, emit, @ctx)
      assert {:ok, first} = Query.one(conn, "SELECT * FROM inbox WHERE id = ?", [inbox_id])

      assert {:ok, _} = record_tool(conn, emit, @ctx)
      assert {:ok, second} = Query.one(conn, "SELECT * FROM inbox WHERE id = ?", [inbox_id])

      assert first.read_at == second.read_at
    end

    test "an unknown inbox id is rejected", %{conn: conn} do
      assert {:error, {:inbox_read, {:missing, :inbox, "nope"}}} =
               record_tool(
                 conn,
                 [%{"type" => "inbox.read", "body" => %{"inbox_id" => "nope"}}],
                 @ctx
               )

      assert count(conn, "events") == 0
    end
  end

  describe "compact action" do
    test "replaces a work's comments with one summary and keeps EVENTS", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      target = %{work_id: work_id}

      first = seed_comment(conn, target, 1, "2026-01-01T00:00:00Z")
      second = seed_comment(conn, target, 2, "2026-01-01T00:01:00Z")
      third = seed_comment(conn, target, 3, "2026-01-01T00:02:00Z")

      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{"work_id" => work_id, "summary" => "resumo"}
                   }
                 ],
                 ctx
               )

      assert event.type == "compact"
      assert event.work_id == work_id

      assert Jason.decode!(event.body) == %{
               "summary" => "resumo",
               "deleted" => [first, second, third]
             }

      assert {:ok, summary} =
               Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

      assert summary.body == "resumo"
      assert summary.author == ctx.author
      assert event.comment_id == summary.id
      assert count(conn, "comments") == 1

      assert {:ok, events} = Store.replay(conn, {:work, work_id})
      assert Enum.map(events, & &1.type) == ["comment", "comment", "comment", "tool", "compact"]
      assert Enum.map(Enum.take(events, 3), & &1.comment_id) == [first, second, third]

      assert {:ok, [only]} = Store.view(conn, "comments.work", work_id)
      assert only.id == summary.id
    end

    test "with ids deletes only the named comments", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      target = %{work_id: work_id}

      first = seed_comment(conn, target, 1, "2026-01-01T00:00:00Z")
      second = seed_comment(conn, target, 2, "2026-01-01T00:01:00Z")
      Fixtures.insert(conn, :comments, %{work_id: work_id, created_at: "2026-01-01T00:02:00Z"})

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{
                       "work_id" => work_id,
                       "summary" => "resumo",
                       "ids" => [second, first]
                     }
                   }
                 ],
                 @ctx
               )

      assert Jason.decode!(event.body)["deleted"] == [first, second]
      assert count(conn, "comments") == 2
    end

    test "an id belonging to another target is refused and writes nothing", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      other_id = Fixtures.insert(conn, :works)
      comment_id = Fixtures.insert(conn, :comments, %{work_id: work_id})
      foreign_id = Fixtures.insert(conn, :comments, %{work_id: other_id})

      assert {:error, {:compact, {:foreign, ^foreign_id}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{
                       "work_id" => work_id,
                       "summary" => "resumo",
                       "ids" => [comment_id, foreign_id]
                     }
                   }
                 ],
                 @ctx
               )

      assert count(conn, "comments") == 2
      assert count(conn, "events") == 0
    end

    test "inside a run on a different work than the target is refused", %{conn: conn} do
      work_a = Fixtures.insert(conn, :works)
      work_b = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_a}

      assert {:error, {:compact, :foreign_work}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{"work_id" => work_b, "summary" => "resumo"}
                   }
                 ],
                 ctx
               )

      assert count(conn, "comments") == 0
      assert count(conn, "events") == 0
    end

    test "no summary is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:error, {:compact, :no_summary}} =
               record_tool(
                 conn,
                 [%{"type" => "compact", "body" => %{"work_id" => work_id}}],
                 @ctx
               )
    end

    test "no target is rejected", %{conn: conn} do
      assert {:error, {:compact, :no_target}} =
               record_tool(
                 conn,
                 [%{"type" => "compact", "body" => %{"summary" => "resumo"}}],
                 @ctx
               )
    end

    test "two targets is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      request_id = Fixtures.insert(conn, :requests)

      assert {:error, {:compact, :many_targets}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{
                       "work_id" => work_id,
                       "request_id" => request_id,
                       "summary" => "resumo"
                     }
                   }
                 ],
                 @ctx
               )
    end

    test "works the same on a request target", %{conn: conn} do
      request_id = Fixtures.insert(conn, :requests)
      Fixtures.insert(conn, :comments, %{request_id: request_id})

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{"request_id" => request_id, "summary" => "resumo"}
                   }
                 ],
                 @ctx
               )

      assert event.request_id == request_id
      assert {:ok, [only]} = Store.view(conn, "comments.request", request_id)
      assert only.body == "resumo"
    end

    test "works the same on an inbox target", %{conn: conn} do
      inbox_id = Fixtures.insert(conn, :inbox)
      Fixtures.insert(conn, :comments, %{inbox_id: inbox_id})

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{"inbox_id" => inbox_id, "summary" => "resumo"}
                   }
                 ],
                 @ctx
               )

      assert event.inbox_id == inbox_id
      assert {:ok, [only]} = Store.view(conn, "comments.inbox", inbox_id)
      assert only.body == "resumo"
    end
  end

  describe "comment.delete action" do
    test "deletes the listed comments and appends an event", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      keep = Fixtures.insert(conn, :comments, %{work_id: work_id})
      first = Fixtures.insert(conn, :comments, %{work_id: work_id})
      second = Fixtures.insert(conn, :comments, %{work_id: work_id})

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "comment.delete",
                     "body" => %{"work_id" => work_id, "ids" => [first, second]}
                   }
                 ],
                 @ctx
               )

      assert event.type == "comment.delete"
      assert event.work_id == work_id
      assert Jason.decode!(event.body) == %{"work_id" => work_id, "ids" => [first, second]}

      assert {:ok, remaining} =
               Query.all(conn, "SELECT id FROM comments WHERE work_id = ?", [work_id])

      assert Enum.map(remaining, & &1.id) == [keep]
    end

    test "an id from another target is refused and writes nothing", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      other_id = Fixtures.insert(conn, :works)
      comment_id = Fixtures.insert(conn, :comments, %{work_id: work_id})
      foreign_id = Fixtures.insert(conn, :comments, %{work_id: other_id})

      assert {:error, {:comment_delete, {:foreign, ^foreign_id}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "comment.delete",
                     "body" => %{"work_id" => work_id, "ids" => [comment_id, foreign_id]}
                   }
                 ],
                 @ctx
               )

      assert count(conn, "comments") == 2
      assert count(conn, "events") == 0
    end

    test "no ids is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:error, {:comment_delete, :no_ids}} =
               record_tool(
                 conn,
                 [%{"type" => "comment.delete", "body" => %{"work_id" => work_id}}],
                 @ctx
               )
    end

    test "replay keeps the comment events for the deleted rows", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id}

      assert {:ok, [_tool_event, comment_event]} =
               record_tool(
                 conn,
                 [%{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "hi"}}],
                 ctx
               )

      assert {:ok, [_tool_event2, delete_event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "comment.delete",
                     "body" => %{"work_id" => work_id, "ids" => [comment_event.comment_id]}
                   }
                 ],
                 ctx
               )

      assert delete_event.type == "comment.delete"

      assert {:ok, events} = Store.replay(conn, {:work, work_id})
      assert Enum.map(events, & &1.type) == ["tool", "comment", "tool", "comment.delete"]
      assert Enum.at(events, 1).comment_id == comment_event.comment_id
    end
  end
end
