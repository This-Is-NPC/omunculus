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

  defp record_tool(conn, emits, ctx), do: Store.record_tools(conn, nil, [{@call, emits}], ctx)

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

  defp request_emit(options) do
    %{"type" => "request", "body" => %{"reason" => "why", "options" => options}}
  end

  defp grant_call(kind, name),
    do: %{"name" => "grant", "args" => %{"kind" => kind, "name" => name}}

  defp access_request(kind, name),
    do: request_emit(%{"grant" => [grant_call(kind, name)], "deny" => []})

  defp open_request(conn, ceiling, work_id) do
    run = Fixtures.open_run(conn, %{ceiling: ceiling})

    {:ok, [_tool_event, event]} =
      record_tool(conn, [access_request("tool", "write")], request_ctx(run, work_id))

    {run, event.request_id}
  end

  defp human_ctx, do: %{@ctx | author: "human", agent: nil}

  defp reply_emit(request_id, option, body) do
    %{
      "type" => "reply",
      "body" => %{"request_id" => request_id, "option" => option, "body" => body}
    }
  end

  defp grant_emit(request_id, extra \\ %{}) do
    body = Map.merge(%{"request_id" => request_id, "name" => "write", "kind" => "tool"}, extra)
    %{"type" => "grant", "body" => body}
  end

  defp cancel_emit(request_id),
    do: %{"type" => "cancel", "body" => %{"request_id" => request_id}}

  defp workspaces_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"

    [agents.worker]
    depth = 1
    text = "worker"

    [workspaces.app]
    root = "app"

    [workspaces.other]
    root = "other"

    [policy]
    workspace = "app"
    """
  end

  defp waiting_parent_and_child(conn, stage) do
    parent_id = Fixtures.insert(conn, :works, %{state: "waiting", waiting: "child"})

    child_id =
      Fixtures.insert(conn, :works, %{
        parent_id: parent_id,
        workflow: stage && "delivery",
        stage: stage,
        assignee: "worker"
      })

    {parent_id, child_id}
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
    workflows = ["delivery"]
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
    workflows = ["delivery"]
    """
  end

  defp no_worker_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"
    """
  end

  defp arbiter_toml do
    """
    [agents.concierge]
    depth = 0
    text = "concierge"
    granted = ["write", "grant"]

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
    granted = ["grant"]
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
               [%{"type" => "prompt", "body" => %{"message" => "count to 5"}}],
               @ctx
             )

    assert event.type == "prompt"
    assert event.run_id == nil

    assert {:ok, prompt} =
             Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [event.prompt_id])

    assert prompt.kind == "message"
    assert prompt.body == "count to 5"
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

  test "a run's prompt reaches only a work of its own conversation", %{conn: conn} do
    other = Omunculus.Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: other,
        created_issuer: "local",
        created_subject: "person",
        created_at: "2026-01-01T00:00:00Z"
      })

    elsewhere = Fixtures.insert(conn, :works, %{conversation_id: other})
    here = Fixtures.insert(conn, :works)
    run = Fixtures.insert(conn, :runs, %{})

    prompt = fn work_id ->
      [%{"type" => "prompt", "body" => %{"message" => "hi", "work_id" => work_id}}]
    end

    assert {:error, {:prompt, {:outside_conversation, ^elsewhere}}} =
             record_tool(conn, prompt.(elsewhere), %{@ctx | run_id: run})

    assert {:ok, [_tool_event, %{type: "prompt"}]} =
             record_tool(conn, prompt.(here), %{@ctx | run_id: run})
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

  test "prompt on a waiting work reopens it before the prompt event", %{conn: conn} do
    work_id =
      Fixtures.insert(conn, :works, %{
        state: "waiting",
        waiting: "request",
        waiting_for: "write",
        waiting_from: "concierge"
      })

    assert {:ok, [_tool_event, work_event, prompt_event]} =
             record_tool(
               conn,
               [%{"type" => "prompt", "body" => %{"message" => "hi", "work_id" => work_id}}],
               @ctx
             )

    assert work_event.type == "work"
    assert work_event.work_id == work_id

    assert Jason.decode!(work_event.body) == %{
             "state" => "open",
             "reason" => "reopened_by_prompt"
           }

    assert prompt_event.type == "prompt"
    assert prompt_event.work_id == work_id

    assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
    assert work.state == "open"
    assert work.waiting == nil
    assert work.waiting_for == nil
    assert work.waiting_from == nil
  end

  test "an action outside the catalogue is unknown and rolls back the tool event", %{
    conn: conn
  } do
    assert {:error, {:unknown_action, "nope"}} =
             record_tool(conn, [%{"type" => "nope", "body" => %{}}], @ctx)

    assert count(conn, "events") == 0
  end

  describe "work action" do
    defp work_emit(item, report \\ "r"),
      do: %{
        "type" => "work",
        "body" => %{
          "report" => report,
          "works" => [Map.merge(%{"goal" => "g", "agent" => "concierge"}, item)]
        }
      }

    test "creates a root work with the report as its first comment and marks it to start", %{
      conn: conn
    } do
      run_id = Fixtures.insert(conn, :runs, %{work_id: nil})
      ctx = %{@ctx | run_id: run_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [work_emit(%{"title" => "Ship the store"}, "planned")],
                 ctx
               )

      assert event.type == "work"
      assert Jason.decode!(event.body)["start"] == true

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert work.title == "Ship the store"
      assert work.goal == "g"
      assert work.assignee == "concierge"
      assert work.stage == nil
      assert work.state == "open"
      assert work.parent_id == nil
      assert work.event_id == event.id

      assert {:ok, [comment]} =
               Query.all(conn, "SELECT * FROM comments WHERE work_id = ?", [event.work_id])

      assert comment.body == "planned"
      assert comment.id == event.comment_id
      assert comment.run_id == run_id

      assert {:ok, run} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
      assert run.work_id == event.work_id
    end

    test "a second work in the same run does not overwrite runs.work_id", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs, %{work_id: nil})
      ctx = %{@ctx | run_id: run_id}

      assert {:ok, [_tool_event, first_event]} =
               record_tool(conn, [work_emit(%{"title" => "first"})], ctx)

      assert {:ok, [_tool_event, _second_event]} =
               record_tool(conn, [work_emit(%{"title" => "second"})], ctx)

      assert {:ok, run} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
      assert run.work_id == first_event.work_id
    end

    test "without a title, a goal or a report it is rejected and writes nothing", %{conn: conn} do
      for {emit, reason} <- [
            {work_emit(%{}), {:invalid, "works"}},
            {work_emit(%{"title" => "t", "goal" => ""}), {:invalid, "works"}},
            {work_emit(%{"title" => "t"}, ""), :no_report},
            {%{"type" => "work", "body" => %{"report" => "r", "works" => []}},
             {:invalid, "works"}}
          ] do
        assert {:error, {:work, ^reason}} = record_tool(conn, [emit], @ctx)
      end

      assert count(conn, "works") == 0
      assert count(conn, "comments") == 0
      assert count(conn, "events") == 0
    end

    test "is rejected when the body carries stage, agent or model", %{conn: conn} do
      for key <- ["stage", "agent", "model"] do
        emit = work_emit(%{"title" => "x"})

        assert {:error, {:work, {:forbidden, ^key}}} =
                 record_tool(conn, [put_in(emit, ["body", key], "v")], @ctx)
      end

      assert count(conn, "works") == 0
    end

    test "with several agents at a depth, a work outside a run must name its agent", %{
      conn: conn
    } do
      config =
        Fixtures.config("""
        [agents.front]
        depth = 0
        text = "front"

        [agents.desk]
        depth = 0
        text = "desk"
        """)

      # The helper names concierge; this work names no one.
      unnamed =
        update_in(work_emit(%{"title" => "x"}), ["body", "works"], fn works ->
          Enum.map(works, &Map.delete(&1, "agent"))
        end)

      assert {:error, {:work, {:agent_required, 0, ["desk", "front"]}}} =
               record_tool(conn, [unnamed], %{
                 @ctx
                 | config: config,
                   agent: nil
               })

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [work_emit(%{"title" => "x", "agent" => "desk"})],
                 %{@ctx | config: config, agent: nil}
               )

      assert {:ok, %{assignee: "desk"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
    end

    test "a named agent must be one of depth 0 or 1 outside workflows", %{conn: conn} do
      config = Fixtures.config(arbiter_toml())

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [work_emit(%{"title" => "x", "agent" => "concierge"})],
                 %{@ctx | config: config}
               )

      assert {:ok, %{assignee: "concierge"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])

      assert {:error, {:work, {:agent_not_allowed, "ghost"}}} =
               record_tool(
                 conn,
                 [work_emit(%{"title" => "x", "agent" => "ghost"})],
                 %{@ctx | config: config}
               )

      assert {:error, {:work, {:workflow_required, ["delivery"]}}} =
               record_tool(
                 conn,
                 [work_emit(%{"title" => "x", "agent" => "concierge"})],
                 %{@ctx | config: Fixtures.config(delivery_toml())}
               )

      assert count(conn, "works") == 1
    end

    test "works naming agents of depth 1 go below a root the run's agent holds", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs, %{work_id: nil})
      ctx = %{@ctx | run_id: run_id, config: Fixtures.config(arbiter_toml())}

      emit = %{
        "type" => "work",
        "body" => %{
          "report" => "two parts",
          "works" => [
            %{"title" => "a", "goal" => "do a", "agent" => "worker"},
            %{"title" => "b", "goal" => "do b", "agent" => "worker"}
          ]
        }
      }

      assert {:ok, [_tool_event, root_event, first, second]} = record_tool(conn, [emit], ctx)
      assert Jason.decode!(root_event.body)["start"] == false
      assert {first.type, second.type} == {"delegate", "delegate"}

      assert {:ok, root} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [root_event.work_id])

      assert {root.title, root.goal, root.assignee} == {"a; b", "do a\n\ndo b", "concierge"}
      assert {root.state, root.waiting} == {"waiting", "child"}

      assert {:ok, children} =
               Query.all(conn, "SELECT * FROM works WHERE parent_id = ? ORDER BY title", [root.id])

      assert Enum.map(children, &{&1.title, &1.assignee}) == [{"a", "worker"}, {"b", "worker"}]

      assert {:ok, %{work_id: work_id}} =
               Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])

      assert work_id == root.id

      mixed = put_in(emit, ["body", "works", Access.at(1), "agent"], "concierge")

      assert {:error, {:work, :one_root}} = record_tool(conn, [mixed], ctx)
    end

    test "a run without delegate keeps an unnamed work as its own root and cannot name a child",
         %{conn: conn} do
      # A root agent that edits but may not delegate, with an agent below it.
      ceiling = %{
        have: ["edit", "end", "work"],
        askable: [],
        sealed: [],
        blocked: [],
        uncited: "blocked"
      }

      run = Fixtures.open_run(conn, %{work_id: nil, ceiling: ceiling})
      ctx = %{@ctx | run_id: run.id, config: Fixtures.config(arbiter_toml())}

      unnamed = %{
        "type" => "work",
        "body" => %{"report" => "r", "works" => [%{"title" => "x", "goal" => "g"}]}
      }

      assert {:ok, [_tool_event, event]} = record_tool(conn, [unnamed], ctx)
      assert Jason.decode!(event.body)["start"] == true

      assert {:ok, [%{assignee: "concierge", parent_id: nil}]} =
               Query.all(conn, "SELECT * FROM works")

      named = put_in(unnamed, ["body", "works", Access.at(0), "agent"], "worker")
      assert {:error, {:work, :no_delegate}} = record_tool(conn, [named], ctx)
    end

    test "with workflow on sets the first stage and its agent", %{conn: conn} do
      ctx = %{@ctx | config: Fixtures.config(delivery_toml())}

      # With a workflow at depth 0 an unnamed work is the root, staged.
      unnamed =
        update_in(work_emit(%{"title" => "Ship it"}), ["body", "works"], fn [item] ->
          [Map.delete(item, "agent")]
        end)

      assert {:ok, [_tool_event, event]} = record_tool(conn, [unnamed], ctx)

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert work.stage == "to_do"
      assert work.assignee == "concierge"
    end

    test "an explicit workspace is stored, none given falls back to the policy default", %{
      conn: conn
    } do
      ctx = %{@ctx | config: Fixtures.config(workspaces_toml())}

      for {body, workspace} <- [{%{"workspace" => "other"}, "other"}, {%{}, "app"}] do
        assert {:ok, [_tool_event, event]} =
                 record_tool(conn, [work_emit(Map.put(body, "title", "x"))], ctx)

        assert {:ok, work} =
                 Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])

        assert work.workspace == workspace
      end
    end

    test "an unknown workspace is rejected and writes nothing", %{conn: conn} do
      ctx = %{@ctx | config: Fixtures.config(workspaces_toml())}

      assert {:error, {:work, {:unknown_workspace, "ghost"}}} =
               record_tool(conn, [work_emit(%{"title" => "x", "workspace" => "ghost"})], ctx)

      assert count(conn, "works") == 0
    end
  end

  describe "continue action" do
    test "without a workflow closes the work and reopens a parent waiting on it", %{
      conn: conn
    } do
      {parent_id, child_id} = waiting_parent_and_child(conn, nil)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: child_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert Jason.decode!(event.body) == %{"from" => nil, "to" => nil, "parent_id" => parent_id}

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
      assert child.state == "done"

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert parent.state == "open"
      assert parent.waiting == nil
    end

    test "waiting work does not advance", %{conn: conn} do
      work_id =
        Fixtures.insert(conn, :works, %{
          workflow: "delivery",
          stage: "to_do",
          state: "waiting",
          waiting: "request",
          waiting_for: "write"
        })

      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:error, {:continue, :waiting}} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.stage == "to_do"
      assert work.waiting_for == "write"
    end

    test "moves to the next stage and updates the assignee", %{conn: conn} do
      work_id =
        Fixtures.insert(conn, :works, %{
          workflow: "delivery",
          stage: "to_do",
          assignee: "concierge"
        })

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
      work_id = Fixtures.insert(conn, :works, %{workflow: "delivery", stage: "review"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert Jason.decode!(event.body) == %{"from" => "review", "to" => nil, "parent_id" => nil}

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "done"
    end

    test "the last stage reopens a parent waiting on this child", %{conn: conn} do
      {parent_id, child_id} = waiting_parent_and_child(conn, "review")
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
      work_id = Fixtures.insert(conn, :works, %{workflow: "delivery", stage: "ghost"})
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
      work_id = Fixtures.insert(conn, :works, %{workflow: "delivery", stage: "to_do"})
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

  describe "reopen action" do
    defp reopen_emit(work_id, body \\ "go on this way"),
      do: %{"type" => "reopen", "body" => %{"work_id" => work_id, "body" => body}}

    test "sends a broken child back to work with the instructions and parks the parent on it",
         %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)

      child_id =
        Fixtures.insert(conn, :works, %{
          parent_id: parent_id,
          assignee: "worker",
          state: "waiting"
        })

      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:ok, [_tool_event, event]} = record_tool(conn, [reopen_emit(child_id)], ctx)
      assert event.type == "reopen"
      assert event.work_id == child_id
      assert Jason.decode!(event.body) == %{"parent_id" => parent_id, "stage" => nil}

      assert {:ok, %{state: "open"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])

      assert {:ok, %{state: "waiting", waiting: "child"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])

      assert {:ok, [%{body: "go on this way"}]} =
               Query.all(conn, "SELECT * FROM comments WHERE work_id = ?", [child_id])
    end

    test "in a workflow, sends the broken work back to a stage up to its own", %{conn: conn} do
      config =
        Fixtures.config("""
        [agents.concierge]
        depth = 0
        text = "c"

        [agents.builder]
        depth = 1
        text = "b"

        [agents.reviewer]
        depth = 1
        workflow_only = true
        text = "r"

        [workflows.delivery]
        steps = [
          { name = "build", agent = "builder" },
          { name = "review", agent = "reviewer" },
          { name = "ship", agent = "builder" },
        ]

        [policy.depth.1]
        workflows = ["delivery"]
        """)

      parent_id = Fixtures.insert(conn, :works)

      child = fn ->
        Fixtures.insert(conn, :works, %{
          parent_id: parent_id,
          workflow: "delivery",
          stage: "review",
          assignee: "reviewer",
          state: "waiting"
        })
      end

      ctx = %{@ctx | run_id: Fixtures.insert(conn, :runs), work_id: parent_id, config: config}
      staged = fn id, body -> update_in(reopen_emit(id), ["body"], &Map.merge(&1, body)) end

      for {body, reason} <- [
            {%{"stage" => "ship"}, {:stage_ahead, "ship"}},
            {%{"stage" => "deploy"}, {:unknown_stage, "deploy"}},
            {%{"stage" => "build", "agent" => "builder"}, :agent_and_stage}
          ] do
        assert {:error, {:reopen, ^reason}} = record_tool(conn, [staged.(child.(), body)], ctx)
      end

      back = child.()

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [staged.(back, %{"stage" => "build"})], ctx)

      assert %{"stage" => "build"} = Jason.decode!(event.body)

      assert {:ok, %{stage: "build", assignee: "builder", state: "open"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [back])
    end

    test "can hand the broken work to another agent of its depth", %{conn: conn} do
      config =
        Fixtures.config("""
        [agents.concierge]
        depth = 0
        text = "c"

        [agents.worker]
        depth = 1
        text = "w"

        [agents.helper]
        depth = 1
        text = "h"
        """)

      parent_id = Fixtures.insert(conn, :works)

      child_id =
        Fixtures.insert(conn, :works, %{
          parent_id: parent_id,
          assignee: "worker",
          state: "waiting"
        })

      ctx = %{@ctx | run_id: Fixtures.insert(conn, :runs), work_id: parent_id, config: config}
      emit = put_in(reopen_emit(child_id), ["body", "agent"], "helper")

      assert {:ok, [_tool_event, _event]} = record_tool(conn, [emit], ctx)

      assert {:ok, %{assignee: "helper", state: "open"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
    end

    test "gives the work what the parent could grant it on a request", %{conn: conn} do
      worker = fn extra -> arbiter_toml() <> extra end

      for {toml, result} <- [
            {worker.(""), :ok},
            {worker.(~s(human = ["write"]\n)), {:reopen, {:only_person, "write"}}},
            {deny_write_toml(), {:reopen, {:cannot_grant, "write"}}}
          ] do
        parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})

        child_id =
          Fixtures.insert(conn, :works, %{
            parent_id: parent_id,
            assignee: "worker",
            state: "waiting"
          })

        ctx = %{
          @ctx
          | run_id: Fixtures.insert(conn, :runs),
            work_id: parent_id,
            config: Fixtures.config(toml)
        }

        emit =
          put_in(reopen_emit(child_id), ["body", "grant"], [
            %{"kind" => "tool", "name" => "write"}
          ])

        case result do
          :ok ->
            assert {:ok, [_tool_event, %{type: "reopen"}, grant]} =
                     record_tool(conn, [emit], ctx)

            assert grant.type == "grant"
            assert grant.request_id == nil
            assert %{"agent" => "worker", "name" => "write"} = Jason.decode!(grant.body)

            assert {:ok, %{grants: ~s(["write"])}} =
                     Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])

          error ->
            assert {:error, ^error} = record_tool(conn, [emit], ctx)
        end
      end
    end

    test "delegating is refused while a child that broke waits on the parent", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, state: "waiting"})
      ctx = %{@ctx | run_id: Fixtures.insert(conn, :runs), work_id: parent_id}
      delegate = %{"type" => "delegate", "body" => %{"title" => "again", "goal" => "g"}}

      assert {:error, {:delegate, {:broken_child, ^child_id}}} =
               record_tool(conn, [delegate], ctx)
    end

    test "refuses a work that is not a broken child of the run's work", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      working = Fixtures.insert(conn, :works, %{parent_id: parent_id, state: "open"})
      stranger = Fixtures.insert(conn, :works, %{state: "waiting"})
      ctx = %{@ctx | run_id: Fixtures.insert(conn, :runs), work_id: parent_id}

      assert {:error, {:reopen, :not_broken}} = record_tool(conn, [reopen_emit(working)], ctx)
      assert {:error, {:reopen, :not_a_child}} = record_tool(conn, [reopen_emit(stranger)], ctx)
      assert {:error, {:reopen, :no_body}} = record_tool(conn, [reopen_emit(working, "")], ctx)
    end
  end

  describe "break action" do
    for {label, stage} <- [{"without a workflow", nil}, {"with a workflow", "to_do"}] do
      test "#{label} parks the child with its comment and reopens the parent waiting on it", %{
        conn: conn
      } do
        {parent_id, child_id} = waiting_parent_and_child(conn, unquote(stage))
        run_id = Fixtures.insert(conn, :runs)
        config = if unquote(stage), do: Fixtures.config(delivery_toml()), else: @ctx.config
        ctx = %{@ctx | run_id: run_id, work_id: child_id, config: config}

        assert {:ok, [_tool_event, event]} =
                 record_tool(
                   conn,
                   [%{"type" => "break", "body" => %{"body" => "need to pause"}}],
                   ctx
                 )

        assert Jason.decode!(event.body) == %{"body" => "need to pause", "parent_id" => parent_id}

        assert {:ok, comment} =
                 Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [child_id])

        assert comment.body == "need to pause"

        assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
        assert child.state == "waiting"
        assert child.stage == unquote(stage)

        assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
        assert parent.state == "open"
        assert parent.waiting == nil
      end
    end

    test "parks a root work with a comment and leaves the stage untouched", %{conn: conn} do
      work_id =
        Fixtures.insert(conn, :works, %{workflow: "delivery", stage: "to_do", state: "open"})

      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: work_id, config: Fixtures.config(delivery_toml())}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "break", "body" => %{"body" => "need to pause"}}],
                 ctx
               )

      assert event.type == "break"
      assert event.work_id == work_id
      assert event.comment_id != nil
      assert Jason.decode!(event.body) == %{"body" => "need to pause", "parent_id" => nil}

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

      assert comment.body == "need to pause"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.stage == "to_do"
      assert work.waiting == nil
      assert work.waiting_from == "concierge"
    end

    test "no body is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{workflow: "delivery", stage: "to_do"})
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
    test "creates a child work with its goal, writes no comment, and parks the parent", %{
      conn: conn
    } do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "delegate",
                     "body" => %{"title" => "Sub task", "goal" => "do this"}
                   }
                 ],
                 ctx
               )

      assert event.type == "delegate"
      assert event.work_id != nil
      assert event.comment_id == nil

      child_id = event.work_id

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [child_id])
      assert child.parent_id == parent_id
      assert child.title == "Sub task"
      assert child.goal == "do this"
      assert child.state == "open"
      assert child.assignee == "worker"
      assert count(conn, "comments") == 0

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert parent.state == "waiting"
      assert parent.waiting == "child"
      assert parent.waiting_for == nil
      assert parent.waiting_from == "concierge"

      assert Jason.decode!(event.body) == %{
               "title" => "Sub task",
               "goal" => "do this",
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
                 [%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b"}}],
                 ctx
               )

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert child.stage == "to_do"
      assert child.assignee == "concierge"
    end

    test "a child picks up a workflow set only at its depth", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(depth1_workflow_toml())
      }

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b"}}],
                 ctx
               )

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert child.stage == "to_do"
      assert child.assignee == "worker"
    end

    test "a named agent takes the child only if its depth allows it outside workflows", %{
      conn: conn
    } do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      delegate =
        &%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b", "agent" => &1}}

      assert {:ok, [_tool_event, event]} = record_tool(conn, [delegate.("worker")], ctx)

      assert {:ok, %{assignee: "worker"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])

      for agent <- ["concierge", "reviewer", "ghost"] do
        assert {:error, {:delegate, {:agent_not_allowed, ^agent}}} =
                 record_tool(conn, [delegate.(agent)], ctx)
      end

      assert {:error, {:delegate, {:workflow_required, ["delivery"]}}} =
               record_tool(
                 conn,
                 [delegate.("worker")],
                 %{ctx | config: Fixtures.config(depth1_workflow_toml())}
               )

      assert count(conn, "works") == 2
    end

    test "a child names a workflow its depth offers, and must where the depth requires several",
         %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      ctx = %{@ctx | run_id: Fixtures.insert(conn, :runs), work_id: parent_id}

      toml = """
      [agents.concierge]
      depth = 0
      text = "concierge"

      [agents.worker]
      depth = 1
      text = "worker"

      [agents.smith]
      depth = 1
      workflow_only = true
      text = "smith"

      [workflows.delivery]
      steps = [{ name = "to_do", agent = "worker" }]

      [workflows.forge]
      steps = [{ name = "shape", agent = "smith" }]

      [workflows.mixed]
      steps = [{ name = "plan", agent = "concierge" }, { name = "do", agent = "worker" }]
      """

      free = %{ctx | config: Fixtures.config(toml)}

      required =
        %{
          ctx
          | config:
              Fixtures.config(toml <> ~s([policy.depth.1]\nworkflows = ["delivery", "forge"]\n))
        }

      delegate =
        &%{"type" => "delegate", "body" => Map.merge(%{"title" => "t", "goal" => "b"}, &1)}

      for c <- [free, required] do
        assert {:ok, [_tool_event, event]} =
                 record_tool(conn, [delegate.(%{"workflow" => "forge"})], c)

        assert {:ok, %{workflow: "forge", stage: "shape", assignee: "smith"}} =
                 Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      end

      for {c, body, reason} <- [
            {free, %{"workflow" => "mixed"},
             {:workflow_not_allowed, "mixed", ["delivery", "forge"]}},
            {free, %{"workflow" => "forge", "agent" => "worker"}, :agent_with_workflow},
            {required, %{}, {:workflow_required, ["delivery", "forge"]}},
            {required, %{"agent" => "worker"}, {:workflow_required, ["delivery", "forge"]}}
          ] do
        assert {:error, {:delegate, ^reason}} = record_tool(conn, [delegate.(body)], c)
      end
    end

    test "the parent waits for all its children; a break wakes it at once", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}
      delegate = &%{"type" => "delegate", "body" => %{"title" => &1, "goal" => "b"}}

      assert {:ok, [_tool_event, first, _tool_event2, second]} =
               Store.record_tools(
                 conn,
                 run_id,
                 [{@call, [delegate.("one")]}, {@call, [delegate.("two")]}],
                 ctx
               )

      parent_state = fn ->
        {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
        parent.state
      end

      continue = fn child_id ->
        {:ok, [_tool_event, event]} =
          record_tool(conn, [%{"type" => "continue", "body" => %{}}], %{ctx | work_id: child_id})

        Jason.decode!(event.body)["parent_id"]
      end

      assert continue.(first.work_id) == nil
      assert parent_state.() == "waiting"
      assert continue.(second.work_id) == parent_id
      assert parent_state.() == "open"

      assert {:ok, [_tool_event, third]} = record_tool(conn, [delegate.("three")], ctx)
      assert {:ok, [_tool_event, _fourth]} = record_tool(conn, [delegate.("four")], ctx)

      assert {:ok, [_tool_event, break]} =
               record_tool(
                 conn,
                 [%{"type" => "break", "body" => %{"body" => "stuck"}}],
                 %{ctx | work_id: third.work_id}
               )

      assert Jason.decode!(break.body)["parent_id"] == parent_id
      assert parent_state.() == "open"
    end

    test "an explicit workspace is stored on the child", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(workspaces_toml())
      }

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "delegate",
                     "body" => %{"title" => "t", "goal" => "b", "workspace" => "other"}
                   }
                 ],
                 ctx
               )

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert child.workspace == "other"
    end

    test "with no workspace given the child inherits the parent's", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{workspace: "other"})
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(workspaces_toml())
      }

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b"}}],
                 ctx
               )

      assert {:ok, child} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [event.work_id])
      assert child.workspace == "other"
    end

    test "an unknown workspace is rejected and writes nothing", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)

      ctx = %{
        @ctx
        | run_id: run_id,
          work_id: parent_id,
          config: Fixtures.config(workspaces_toml())
      }

      assert {:error, {:delegate, {:unknown_workspace, "ghost"}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "delegate",
                     "body" => %{"title" => "t", "goal" => "b", "workspace" => "ghost"}
                   }
                 ],
                 ctx
               )

      assert count(conn, "works") == 1
    end

    test "no work is rejected", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: nil}

      assert {:error, {:delegate, :no_work}} =
               record_tool(
                 conn,
                 [%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b"}}],
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
                 [%{"type" => "delegate", "body" => %{"title" => "t", "goal" => "b"}}],
                 ctx
               )
    end

    test "no title is rejected", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      assert {:error, {:delegate, :no_title}} =
               record_tool(conn, [%{"type" => "delegate", "body" => %{"goal" => "b"}}], ctx)
    end

    test "no goal is rejected and writes nothing", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: parent_id}

      for body <- [%{"title" => "t"}, %{"title" => "t", "goal" => ""}] do
        assert {:error, {:delegate, :no_goal}} =
                 record_tool(conn, [%{"type" => "delegate", "body" => body}], ctx)
      end

      assert count(conn, "works") == 1
      assert count(conn, "events") == 0
    end
  end

  describe "end action" do
    test "appends an end event for the run and its work", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      run_id = Fixtures.insert(conn, :runs, %{work_id: work_id})
      ctx = %{@ctx | run_id: run_id, work_id: work_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "end", "body" => %{}}], ctx)

      assert event.type == "end"
      assert event.run_id == run_id
      assert event.work_id == work_id

      assert {:ok, %{state: "open"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
    end

    test "a run without a work may end", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)

      assert {:ok, [_tool_event, %{type: "end", work_id: nil}]} =
               record_tool(conn, [%{"type" => "end", "body" => %{}}], %{@ctx | run_id: run_id})
    end

    test "no run is rejected and writes nothing", %{conn: conn} do
      assert {:error, {:end, :no_run}} =
               record_tool(conn, [%{"type" => "end", "body" => %{}}], @ctx)

      assert count(conn, "events") == 0
    end

    test "a body field is an unknown field", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)

      assert {:error, {:invalid_emit, "end", {:unknown_field, "work_id"}}} =
               record_tool(
                 conn,
                 [%{"type" => "end", "body" => %{"work_id" => "x"}}],
                 %{@ctx | run_id: run_id}
               )
    end
  end

  describe "request action" do
    test "have on every grant of an access request refuses it, saying the run has them", %{
      conn: conn
    } do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      before = count(conn, "events")

      assert {:error, {:request, {:already_have, "comment"}}} =
               record_tool(conn, [access_request("tool", "comment")], request_ctx(run))

      assert count(conn, "requests") == 0
      assert count(conn, "events") == before
    end

    test "a blocked grant refuses the request and writes nothing", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      before = count(conn, "events")

      assert {:error, {:request, {:blocked, "delete"}}} =
               record_tool(conn, [access_request("tool", "delete")], request_ctx(run))

      assert count(conn, "requests") == 0
      assert count(conn, "events") == before
    end

    test "stores the options, comments the reason and parks the work on the request", %{
      conn: conn
    } do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "write")], request_ctx(run, work_id))

      assert event.type == "request"
      assert event.request_id != nil
      assert event.comment_id != nil

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "human"
      assert request.status == "waiting_human"
      assert request.agent == run.agent
      assert request.work_id == work_id

      assert Jason.decode!(request.options) == %{
               "grant" => [
                 %{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write"}}
               ],
               "deny" => []
             }

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE request_id = ?", [event.request_id])

      assert comment.body == "why"
      assert comment.event_id == event.id

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.waiting == "request"
      assert work.waiting_for == event.request_id
      assert work.waiting_from == run.agent
    end

    test "a sealed grant goes to the human even with an arbiter above", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run, work_id, Fixtures.config(arbiter_toml()))

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "deploy")], ctx)

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "human"
      assert request.status == "waiting_human"
    end

    test "a name in no list follows the ceiling's uncited class", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("directory", "./secrets")], request_ctx(run))

      assert event.type == "request"
    end

    test "a request whose options grant nothing opens a row", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      emit = request_emit(%{"cancel" => [%{"name" => "cancel"}], "retry" => []})

      assert {:ok, [_tool_event, event]} = record_tool(conn, [emit], request_ctx(run))
      assert event.type == "request"
      assert count(conn, "requests") == 1
    end

    test "malformed options are rejected and write nothing", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      for options <- [
            %{},
            %{"grant" => "grant"},
            %{"grant" => [%{"args" => %{}}]},
            %{"grant" => [%{"name" => "grant", "args" => %{"name" => "write"}}]}
          ] do
        assert {:error, {:request, {:invalid, :options}}} =
                 record_tool(conn, [request_emit(options)], request_ctx(run))
      end

      assert count(conn, "events") == 1
    end

    test "a missing reason is rejected and writes nothing", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      assert {:error, {:request, :no_reason}} =
               record_tool(
                 conn,
                 [%{"type" => "request", "body" => %{"options" => %{"deny" => []}}}],
                 request_ctx(run)
               )

      assert count(conn, "events") == 1
    end

    test "no run is rejected and writes nothing", %{conn: conn} do
      assert {:error, {:request, :no_run}} =
               record_tool(conn, [access_request("tool", "write")], @ctx)

      assert count(conn, "events") == 0
    end

    test "a request without a linked work leaves work_id nil and touches no work", %{
      conn: conn
    } do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "write")], request_ctx(run))

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.work_id == nil
      assert count(conn, "works") == 0
    end

    test "every option tool have for the parent's agent routes to that agent", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run, work_id, Fixtures.config(arbiter_toml()))

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "write")], ctx)

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "concierge"
      assert request.status == "waiting_agent"

      body = Jason.decode!(event.body)
      assert body["arbiter"] == "concierge"
      assert body["arbiter_work_id"] == parent_id
    end

    test "a decision goes to the agent above, or to the person when it says so", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      config = Fixtures.config(arbiter_toml())

      arbiter = fn extra ->
        work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
        run = Fixtures.open_run(conn, %{ceiling: @ceiling})

        body =
          Map.merge(%{"reason" => "ship it?", "options" => %{"yes" => [], "no" => []}}, extra)

        {:ok, [_tool_event, event]} =
          record_tool(
            conn,
            [%{"type" => "request", "body" => body}],
            request_ctx(run, work_id, config)
          )

        {:ok, request} =
          Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

        request.arbiter
      end

      assert arbiter.(%{}) == "concierge"
      assert arbiter.(%{"to" => "person"}) == "human"

      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      assert {:error, {:request, {:invalid, "to"}}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "request",
                     "body" => %{"reason" => "r", "options" => %{"a" => []}, "to" => "nobody"}
                   }
                 ],
                 request_ctx(run, nil, config)
               )
    end

    test "an option calling a tool only the person may give the requester goes to the person",
         %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: %{@ceiling | askable: [], sealed: ["write"]}})
      ctx = request_ctx(run, work_id, Fixtures.config(arbiter_toml()))
      calling = request_emit(%{"apply" => [%{"name" => "write", "args" => %{}}], "deny" => []})

      assert {:ok, [_tool_event, event]} = record_tool(conn, [calling], ctx)

      assert {:ok, %{arbiter: "human", status: "waiting_human"}} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])
    end

    test "an option tool the parent's agent does not have falls back to human", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run, work_id, Fixtures.config(arbiter_toml()))

      options = %{
        "grant" => [grant_call("tool", "write")],
        "cancel" => [%{"name" => "cancel"}]
      }

      assert {:ok, [_tool_event, event]} = record_tool(conn, [request_emit(options)], ctx)

      assert {:ok, %{arbiter: "human"}} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])
    end

    test "a grant the parent's agent is denied falls back to human", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run, work_id, Fixtures.config(deny_write_toml()))

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "write")], ctx)

      assert {:ok, request} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])

      assert request.arbiter == "human"
      assert request.status == "waiting_human"
      refute Map.has_key?(Jason.decode!(event.body), "arbiter")
    end

    test "a request by the harness goes to the human", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})

      ctx = %{
        request_ctx(run, work_id, Fixtures.config(arbiter_toml()))
        | author: "harness"
      }

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [access_request("tool", "write")], ctx)

      assert {:ok, %{arbiter: "human"}} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [event.request_id])
    end
  end

  describe "reply action" do
    test "closes the request, comments its body and reopens the waiting work", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:ok, [_tool_event, reply_event]} =
               record_tool(conn, [reply_emit(request_id, "deny", "not now")], human_ctx())

      assert reply_event.type == "reply"
      assert reply_event.work_id == work_id

      assert {:ok, %{status: "closed"}} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert {:ok, comment} =
               Query.one(conn, "SELECT * FROM comments WHERE request_id = ? AND event_id = ?", [
                 request_id,
                 reply_event.id
               ])

      assert comment.body == "not now"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"
      assert work.waiting == nil
      assert work.grants == nil
    end

    test "leaves alone a work that no longer waits on the request", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)
      :ok = Query.exec(conn, "UPDATE works SET state = 'done' WHERE id = ?", [work_id])

      assert {:ok, _events} =
               record_tool(conn, [reply_emit(request_id, "deny", "late")], human_ctx())

      assert {:ok, %{state: "done"}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
    end

    test "replying to a closed request is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)
      emit = reply_emit(request_id, "deny", "ok")

      assert {:ok, _events} = record_tool(conn, [emit], human_ctx())
      assert {:error, {:reply, :closed}} = record_tool(conn, [emit], human_ctx())
    end

    test "a missing request is rejected", %{conn: conn} do
      assert {:error, {:reply, {:missing, :requests, "nope"}}} =
               record_tool(conn, [reply_emit("nope", "deny", "ok")], @ctx)
    end

    test "an option the request does not have is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:error, {:reply, {:unknown_option, "maybe", ["deny" | _]}}} =
               record_tool(conn, [reply_emit(request_id, "maybe", "ok")], human_ctx())
    end

    test "an empty reply body is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:error, {:reply, :no_body}} =
               record_tool(conn, [reply_emit(request_id, "deny", "")], human_ctx())
    end

    test "an agent that is not the arbiter is refused", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:error, {:reply, :not_arbiter}} =
               record_tool(conn, [reply_emit(request_id, "deny", "no")], request_ctx(run))

      assert {:ok, %{status: "waiting_human"}} =
               Query.one(conn, "SELECT * FROM requests WHERE id = ?", [request_id])
    end

    test "the arbiter agent may reply", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works, %{assignee: "concierge"})
      work_id = Fixtures.insert(conn, :works, %{parent_id: parent_id, assignee: "worker"})
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run, work_id, Fixtures.config(arbiter_toml()))
      {:ok, [_tool, request]} = record_tool(conn, [access_request("tool", "write")], ctx)
      arbiter_ctx = %{ctx | agent: "concierge", work_id: parent_id}

      assert {:ok, [_tool_event, _reply_event]} =
               record_tool(conn, [reply_emit(request.request_id, "deny", "no")], arbiter_ctx)
    end
  end

  describe "grant action" do
    test "a temporary grant adds the name to the request's work", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:ok, [_tool_event, _reply_event, grant_event]} =
               record_tool(
                 conn,
                 [reply_emit(request_id, "grant", "ok"), grant_emit(request_id)],
                 human_ctx()
               )

      assert grant_event.type == "grant"
      assert grant_event.request_id == request_id
      assert grant_event.work_id == work_id

      body = Jason.decode!(grant_event.body)
      assert body["name"] == "write"
      assert body["kind"] == "tool"
      assert body["agent"] == run.agent
      assert body["depth"] == 0
      assert body["scope"] == nil

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["write"]
      assert work.state == "open"
    end

    test "a scoped grant from the human writes the event but not works.grants", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:ok, [_tool_event, grant_event]} =
               record_tool(conn, [grant_emit(request_id, %{"scope" => "agent"})], human_ctx())

      assert Jason.decode!(grant_event.body)["scope"] == "agent"

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.grants == nil
    end

    test "a scoped grant from an agent is refused and the batch writes nothing", %{
      conn: conn
    } do
      work_id = Fixtures.insert(conn, :works)
      {run, request_id} = open_request(conn, @ceiling, work_id)
      before = count(conn, "events")

      assert {:error, {:grant, :not_human}} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "comment",
                     "body" => %{"request_id" => request_id, "body" => "ok"}
                   },
                   grant_emit(request_id, %{"scope" => "agent"})
                 ],
                 %{human_ctx() | author: "agent", agent: run.agent}
               )

      assert count(conn, "events") == before
    end

    test "an invalid scope is rejected", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:error, {:grant, {:invalid, :scope}}} =
               record_tool(conn, [grant_emit(request_id, %{"scope" => "project"})], human_ctx())
    end

    test "a request with no linked work only writes the grant event", %{conn: conn} do
      {_run, request_id} = open_request(conn, @ceiling, nil)

      assert {:ok, [_tool_event, grant_event]} =
               record_tool(conn, [grant_emit(request_id)], human_ctx())

      assert grant_event.type == "grant"
      assert count(conn, "works") == 0
    end
  end

  describe "cancel action" do
    test "cancel sets the request's work cancelled", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)

      assert {:ok, [_tool_event, _reply_event, event]} =
               record_tool(
                 conn,
                 [
                   reply_emit(request_id, "deny", "stop"),
                   cancel_emit(request_id)
                 ],
                 human_ctx()
               )

      assert event.type == "cancel"
      assert Jason.decode!(event.body)["parent_id"] == nil

      assert {:ok, %{state: "cancelled", waiting: nil}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
    end

    test "cancelling the last open child wakes its waiting parent", %{conn: conn} do
      {parent_id, child_id} = waiting_parent_and_child(conn, nil)
      Fixtures.insert(conn, :works, %{parent_id: parent_id, state: "done"})
      {_run, request_id} = open_request(conn, @ceiling, child_id)

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [cancel_emit(request_id)], human_ctx())

      assert Jason.decode!(event.body)["parent_id"] == parent_id

      assert {:ok, %{state: "open", waiting: nil}} =
               Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
    end

    test "a cancelled sibling counts as closed when the last child is done", %{conn: conn} do
      {parent_id, child_id} = waiting_parent_and_child(conn, nil)
      Fixtures.insert(conn, :works, %{parent_id: parent_id, state: "cancelled"})
      run_id = Fixtures.insert(conn, :runs)
      ctx = %{@ctx | run_id: run_id, work_id: child_id}

      assert {:ok, [_tool_event, event]} =
               record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx)

      assert Jason.decode!(event.body)["parent_id"] == parent_id
    end

    test "a work already done or cancelled is refused", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {_run, request_id} = open_request(conn, @ceiling, work_id)
      :ok = Query.exec(conn, "UPDATE works SET state = 'cancelled' WHERE id = ?", [work_id])

      assert {:error, {:cancel, {:closed, "cancelled"}}} =
               record_tool(conn, [cancel_emit(request_id)], human_ctx())
    end

    test "a request with no work is refused", %{conn: conn} do
      {_run, request_id} = open_request(conn, @ceiling, nil)

      assert {:error, {:cancel, :no_work}} =
               record_tool(conn, [cancel_emit(request_id)], human_ctx())
    end
  end

  describe "notify action" do
    test "inside a run on a work appends inbox, comment, and event; run and work are untouched",
         %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      work_id = Fixtures.insert(conn, :works, %{state: "open"})
      ctx = request_ctx(run, work_id)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "notify", "body" => %{"body" => "need to notify"}}],
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

      assert comment.body == "need to notify"
      assert comment.event_id == event.id

      assert {:ok, work} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"
      assert work.waiting == nil

      assert {:ok, run_row} = Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run.id])
      assert run_row.status == "open"
    end

    test "without a work leaves inbox.work_id nil", %{conn: conn} do
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = request_ctx(run)

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [%{"type" => "notify", "body" => %{"body" => "loose notice"}}],
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
                     "body" => %{"body" => "notice", "work_id" => "nope"}
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
                 [%{"type" => "notify", "body" => %{"body" => "notice"}}],
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
                     "body" => %{"work_id" => work_id, "summary" => "summary"}
                   }
                 ],
                 ctx
               )

      assert event.type == "compact"
      assert event.work_id == work_id

      assert Jason.decode!(event.body) == %{
               "summary" => "summary",
               "deleted" => [first, second, third]
             }

      assert {:ok, summary} =
               Query.one(conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

      assert summary.body == "summary"
      assert summary.author == ctx.author
      assert event.comment_id == summary.id
      assert count(conn, "comments") == 1

      assert {:ok, events} = Store.replay(conn, {:work, work_id})
      assert Enum.map(events, & &1.type) == ["comment", "comment", "comment", "tool", "compact"]
      assert Enum.map(Enum.take(events, 3), & &1.comment_id) == [first, second, third]

      assert {:ok, [only]} = Store.comments(conn, :work, work_id)
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
                       "summary" => "summary",
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
                       "summary" => "summary",
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
                     "body" => %{"work_id" => work_b, "summary" => "summary"}
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
                 [%{"type" => "compact", "body" => %{"summary" => "summary"}}],
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
                       "summary" => "summary"
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
                     "body" => %{"request_id" => request_id, "summary" => "summary"}
                   }
                 ],
                 @ctx
               )

      assert event.request_id == request_id
      assert {:ok, [only]} = Store.comments(conn, :request, request_id)
      assert only.body == "summary"
    end

    test "works the same on an inbox target", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      inbox_id = Fixtures.insert(conn, :inbox, %{work_id: work_id})
      Fixtures.insert(conn, :comments, %{inbox_id: inbox_id})

      assert {:ok, [_tool_event, event]} =
               record_tool(
                 conn,
                 [
                   %{
                     "type" => "compact",
                     "body" => %{"inbox_id" => inbox_id, "summary" => "summary"}
                   }
                 ],
                 @ctx
               )

      assert event.inbox_id == inbox_id
      assert {:ok, [only]} = Store.comments(conn, :inbox, inbox_id)
      assert only.body == "summary"
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

  describe "a work waiting on its children" do
    test "takes comment, delegate and end, and refuses continue, break and request",
         %{conn: conn} do
      {parent_id, _child_id} = waiting_parent_and_child(conn, nil)
      run = Fixtures.open_run(conn, %{ceiling: @ceiling})
      ctx = %{request_ctx(run, parent_id) | config: Fixtures.config(delivery_toml())}

      comment = %{"type" => "comment", "body" => %{"work_id" => parent_id, "body" => "noted"}}
      delegate = %{"type" => "delegate", "body" => %{"title" => "more", "goal" => "more goal"}}

      assert {:ok, [_tool, %{type: "comment"}, %{type: "delegate"}, %{type: "end"}]} =
               Store.record_tools(
                 conn,
                 run.id,
                 [{@call, [comment, delegate, %{"type" => "end", "body" => %{}}]}],
                 ctx
               )

      for {emit, refusal} <- [
            {%{"type" => "continue", "body" => %{}}, {:continue, :waiting}},
            {%{"type" => "break", "body" => %{"body" => "stuck"}}, {:break, :waiting_children}},
            {request_emit(%{"grant" => [grant_call("tool", "write")], "deny" => []}),
             {:request, :waiting_children}}
          ] do
        assert {:error, ^refusal} = Store.record_tools(conn, run.id, [{@call, [emit]}], ctx)
      end

      assert {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
      assert {parent.state, parent.waiting} == {"waiting", "child"}
    end

    test "reopens once when two children close at the same time from two processes",
         %{conn: conn} do
      {parent_id, first} = waiting_parent_and_child(conn, "review")

      second =
        Fixtures.insert(conn, :works, %{
          parent_id: parent_id,
          workflow: "delivery",
          stage: "review",
          assignee: "worker"
        })

      config = Fixtures.config(delivery_toml())

      events =
        [first, second]
        |> Enum.map(fn child_id ->
          run_id = Fixtures.insert(conn, :runs)
          ctx = %{@ctx | run_id: run_id, work_id: child_id, config: config}
          Task.async(fn -> record_tool(conn, [%{"type" => "continue", "body" => %{}}], ctx) end)
        end)
        |> Task.await_many()
        |> Enum.map(fn {:ok, [_tool, continue]} -> Jason.decode!(continue.body)["parent_id"] end)

      assert Enum.sort(events, :desc) == [parent_id, nil]
      assert {:ok, %{state: "open"}} = Store.view(conn, "work", parent_id)
    end
  end
end
