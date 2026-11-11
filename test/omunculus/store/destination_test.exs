defmodule Omunculus.Store.DestinationTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Fixtures, Id, Participant, Store}
  alias Omunculus.Store.{Destination, Query, View}

  @config """
  [agents.root]
  depth = 0
  text = "root"
  [agents.stage]
  depth = 0
  workflow_only = true
  text = "stage"
  [agents.lead]
  depth = 1
  text = "lead"
  [agents.worker]
  depth = 2
  text = "worker"
  [accounts]
  owner = { kind = "human", issuer = "test", subject = "boss" }
  desk = { kind = "agent", agent = "root" }
  """

  setup %{conn: conn} do
    conversation = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: conversation,
        created_issuer: "test",
        created_subject: "client",
        created_at: "2026-01-01"
      })

    root = Fixtures.insert(conn, :works, %{assignee: "root", conversation_id: conversation})

    lead =
      Fixtures.insert(conn, :works, %{
        assignee: "lead",
        parent_id: root,
        conversation_id: conversation
      })

    worker =
      Fixtures.insert(conn, :works, %{
        assignee: "worker",
        parent_id: lead,
        conversation_id: conversation
      })

    %{
      config: Fixtures.config(@config),
      conversation: conversation,
      works: %{"root" => root, "lead" => lead, "worker" => worker}
    }
  end

  defp resolve(conn, ctx, agent, to, forbidden \\ []) do
    {:ok, work} = View.view(conn, "work", ctx.works[agent])
    context = %{config: ctx.config, conversation_id: ctx.conversation}
    Destination.resolve(conn, context, nil, work, Participant.agent(agent), to, forbidden)
  end

  test "an ask without to goes to the requester for a root work", %{conn: conn} = ctx do
    assert {:ok, requester, nil} = resolve(conn, ctx, "root", nil)
    assert requester == Participant.human("test", "client")
  end

  test "an ask without to goes to the assignee of the parent work", %{conn: conn} = ctx do
    assert {:ok, lead, lead_work} = resolve(conn, ctx, "worker", nil)
    assert {lead, lead_work} == {Participant.agent("lead"), ctx.works["lead"]}
    assert {:ok, root, root_work} = resolve(conn, ctx, "lead", nil)
    assert {root, root_work} == {Participant.agent("root"), ctx.works["root"]}
  end

  test "an ask without to has nobody when the parent work has no assignee", %{conn: conn} = ctx do
    orphan = Fixtures.insert(conn, :works, %{parent_id: nil, assignee: nil})
    child = Fixtures.insert(conn, :works, %{parent_id: orphan, assignee: "worker"})
    {:ok, work} = View.view(conn, "work", child)
    context = %{config: ctx.config, conversation_id: ctx.conversation}

    assert {:error, {:request, :no_route}} =
             Destination.resolve(conn, context, nil, work, Participant.agent("worker"), nil, [])
  end

  test "to names an account, an agent's too", %{conn: conn} = ctx do
    assert {:ok, owner, nil} = resolve(conn, ctx, "worker", "owner")
    assert owner == Participant.human("test", "boss")
    assert {:ok, desk, root_work} = resolve(conn, ctx, "worker", "desk")
    assert {desk, root_work} == {Participant.agent("root"), ctx.works["root"]}
  end

  test "to names an agent above the work, with that work", %{conn: conn} = ctx do
    assert {:ok, root, root_work} = resolve(conn, ctx, "worker", "root")
    assert {root, root_work} == {Participant.agent("root"), ctx.works["root"]}
    assert {:ok, lead, lead_work} = resolve(conn, ctx, "worker", "lead")
    assert {lead, lead_work} == {Participant.agent("lead"), ctx.works["lead"]}
  end

  test "to names an agent of depth 0 that talks with the person, without a work", %{conn: conn} do
    config = Fixtures.config(@config)
    other = Fixtures.insert(conn, :works, %{assignee: "worker"})
    {:ok, work} = View.view(conn, "work", other)

    assert {:ok, root, nil} =
             Destination.resolve(
               conn,
               %{config: config},
               nil,
               work,
               Participant.agent("worker"),
               "root",
               []
             )

    assert root == Participant.agent("root")
  end

  test "to refuses an unknown name and lists what it takes", %{conn: conn} = ctx do
    assert {:error, {:request, {:unknown_account, "nobody", names}} = reason} =
             resolve(conn, ctx, "worker", "nobody")

    assert names == ~w(desk lead owner root stage worker)

    assert Omunculus.Tools.Out.refused(reason) =~
             ~s(refused: "nobody" is neither an account nor an agent; to takes one of: desk, lead, owner, root, stage, worker)
  end

  test "to refuses oneself", %{conn: conn} = ctx do
    assert {:error, {:request, {:ask_self, "worker"}}} = resolve(conn, ctx, "worker", "worker")
    assert {:error, {:request, {:ask_self, "desk"}}} = resolve(conn, ctx, "root", "desk")
  end

  test "to refuses a workflow-only agent outside the work's chain", %{conn: conn} = ctx do
    assert {:error, {:request, {:unreachable, "stage"}} = reason} =
             resolve(conn, ctx, "worker", "stage")

    assert Omunculus.Tools.Out.refused(reason) =~ "cannot be asked from this work"
  end

  test "an unknown account refuses the ask without creating a request", %{conn: conn} = ctx do
    run = Fixtures.open_run(conn, %{agent: "worker", work_id: ctx.works["worker"]})

    ctx_map = %{
      run_id: run.id,
      work_id: ctx.works["worker"],
      author: "agent",
      agent: "worker",
      config: ctx.config,
      groups: %{}
    }

    body = %{"reason" => "Question", "options" => %{}, "to" => "nobody"}

    assert {:error, {:request, {:unknown_account, "nobody", _names}}} =
             Store.record_tools(
               conn,
               run.id,
               [{%{name: "ask", args: %{}}, [%{"type" => "request", "body" => body}]}],
               ctx_map
             )

    assert {:ok, []} = Query.all(conn, "SELECT id FROM requests")
  end

  describe "escalation and the harness" do
    setup %{conn: conn} = ctx do
      run = fn agent ->
        Fixtures.open_run(conn, %{
          agent: agent,
          depth: ctx.config.agents[agent].depth,
          work_id: ctx.works[agent],
          conversation_id: ctx.conversation,
          ceiling: %{
            have: ["ask", "escalate", "end"],
            askable: [],
            sealed: [],
            blocked: [],
            uncited: "askable",
            overrides: %{}
          }
        })
      end

      act = fn agent, type, body ->
        run = run.(agent)

        context = %{
          run_id: run.id,
          work_id: ctx.works[agent],
          author: "agent",
          agent: agent,
          config: ctx.config,
          groups: %{},
          conversation_id: ctx.conversation
        }

        call = %{name: type, args: body, ok: true, output: ""}

        {:ok, events} =
          Store.record_tools(conn, run.id, [{call, [%{"type" => type, "body" => body}]}], context)

        Enum.find(events, &(&1.type == "request"))
      end

      %{act: act}
    end

    test "an escalation climbs one level, to the escalator's parent", %{conn: conn, act: act} do
      asked = act.("worker", "request", %{"reason" => "Which logo?", "options" => %{}})

      at_lead =
        act.("lead", "escalate", %{
          "reason" => "Which logo?",
          "origins" => %{"logo" => asked.request_id}
        })

      {:ok, request} = View.view(conn, "request", at_lead.request_id)
      assert Jason.decode!(request.arbiter) == Participant.agent("root")

      at_requester =
        act.("root", "escalate", %{
          "reason" => "Which logo?",
          "origins" => %{"logo" => at_lead.request_id}
        })

      {:ok, request} = View.view(conn, "request", at_requester.request_id)
      assert Jason.decode!(request.arbiter) == Participant.human("test", "client")
    end

    test "an unanswered request passed on by the harness goes to the parent", %{
      conn: conn,
      config: config,
      act: act,
      works: works,
      conversation: conversation
    } do
      asked = act.("worker", "request", %{"reason" => "Which logo?", "options" => %{}})

      run =
        Fixtures.open_run(conn, %{
          agent: "lead",
          depth: 1,
          work_id: works["lead"],
          conversation_id: conversation,
          request_id: asked.request_id
        })

      {:ok, _} = Store.close_run(conn, run.id)
      {:ok, closed} = Store.view(conn, "run", run.id)

      assert {:ok, events} =
               Store.unanswered(conn, closed, config, &Omunculus.Tools.Out.unanswered/3)

      upstream = Enum.find(events, &(&1.type == "request"))
      {:ok, request} = View.view(conn, "request", upstream.request_id)
      assert Jason.decode!(request.arbiter) == Participant.agent("root")
      assert {:ok, %{status: "escalated"}} = View.view(conn, "request", asked.request_id)
    end
  end
end
