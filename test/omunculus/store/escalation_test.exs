Code.require_file("../../../eval/lib/task.ex", __DIR__)
Code.require_file("../../../eval/lib/requests.ex", __DIR__)

defmodule Omunculus.Store.EscalationTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Fixtures, Id, Participant, Store}
  alias Omunculus.Store.{Query, View}

  @agents """
  [agents.root]
  depth = 0
  text = "root"
  tools = ["reply", "escalate", "end", "grant", "cancel"]
  [agents.lead]
  depth = 1
  text = "lead"
  tools = ["reply", "escalate", "end", "grant", "cancel"]
  [agents.worker]
  depth = 2
  text = "worker"
  tools = ["ask", "end"]
  """
  setup %{conn: conn} do
    config = Fixtures.config(@agents)
    conversation_id = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: conversation_id,
        created_issuer: "test",
        created_subject: "owner",
        created_at: "2026-01-01"
      })

    root =
      Fixtures.insert(conn, :works, %{
        assignee: "root",
        conversation_id: conversation_id,
        state: "waiting",
        waiting: "child"
      })

    lead =
      Fixtures.insert(conn, :works, %{
        assignee: "lead",
        parent_id: root,
        conversation_id: conversation_id,
        state: "waiting",
        waiting: "child"
      })

    children =
      for title <- ~w(logo tone),
          do:
            Fixtures.insert(conn, :works, %{
              assignee: "worker",
              parent_id: lead,
              conversation_id: conversation_id,
              title: title
            })

    root_ctx = context(conn, config, root, "root", 0, conversation_id)
    lead_ctx = context(conn, config, lead, "lead", 1, conversation_id)
    child_ctxs = Enum.map(children, &context(conn, config, &1, "worker", 2, conversation_id))
    owner = human(config, conversation_id, "owner")

    %{
      config: config,
      conversation: conversation_id,
      root: root,
      lead: lead,
      children: children,
      root_ctx: root_ctx,
      lead_ctx: lead_ctx,
      child_ctxs: child_ctxs,
      owner: owner
    }
  end

  defp context(conn, config, work, agent, depth, conversation) do
    run =
      Fixtures.open_run(conn, %{
        agent: agent,
        depth: depth,
        work_id: work,
        conversation_id: conversation,
        ceiling: %{
          have: ["ask", "reply", "escalate", "end", "grant"],
          askable: ["write"],
          sealed: ["deploy", "promote"],
          blocked: [],
          uncited: "askable",
          overrides: %{}
        }
      })

    %{
      run_id: run.id,
      work_id: work,
      author: "agent",
      agent: agent,
      config: config,
      groups: %{},
      conversation_id: conversation
    }
  end

  defp human(config, conversation, subject),
    do: %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "test",
      subject: subject,
      config: config,
      groups: %{},
      conversation_id: conversation
    }

  defp human_origin(conn, ctx, subject) do
    work =
      Fixtures.insert(conn, :works, %{
        parent_id: ctx.root,
        assignee: nil,
        conversation_id: ctx.conversation
      })

    human(ctx.config, ctx.conversation, subject) |> Map.put(:work_id, work)
  end

  defp apply_action(conn, type, body, ctx) do
    call = %{name: type, args: body, ok: true, output: ""}
    Store.record_tools(conn, ctx.run_id, [{call, [%{"type" => type, "body" => body}]}], ctx)
  end

  defp ask(conn, ctx, reason, options \\ %{"answer" => []}) do
    assert {:ok, events} =
             apply_action(conn, "request", %{"reason" => reason, "options" => options}, ctx)

    Enum.find(events, &(&1.type == "request")).request_id
  end

  defp escalate(conn, ctx, origins) do
    assert {:ok, events} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Answer these named questions.", "origins" => origins},
               ctx
             )

    Enum.find(events, &(&1.type == "request")).request_id
  end

  defp reply(conn, ctx, id, answer),
    do: apply_action(conn, "reply", Map.put(answer, "request_id", id), ctx)

  defp request(conn, id) do
    {:ok, request} = View.view(conn, "request", id)
    request
  end

  defp work(conn, id) do
    {:ok, work} = View.view(conn, "work", id)
    work
  end

  defp count(conn, table) do
    {:ok, %{count: count}} = Query.one(conn, "SELECT count(*) AS count FROM #{table}")
    count
  end

  defp questions(conn, ctx) do
    [logo, tone] = Enum.zip_with(ctx.child_ctxs, ~w(logo tone), &ask(conn, &1, &2))
    merged = escalate(conn, ctx.lead_ctx, %{"logo" => logo, "tone" => tone})
    {logo, tone, merged}
  end

  test "three levels merge questions and named parts return only each origin's answer",
       %{conn: conn} = ctx do
    {logo, tone, merged} = questions(conn, ctx)
    upstream = escalate(conn, ctx.root_ctx, %{"design" => merged})
    assert work(conn, ctx.lead).waiting == "child"
    assert work(conn, ctx.root).waiting == "child"
    assert request(conn, logo).status == "escalated"
    assert request(conn, merged).status == "escalated"
    assert Jason.decode!(request(conn, upstream).arbiter) == Participant.human("test", "owner")
    assert request(conn, upstream).origins["design"].origins["logo"].id == logo

    assert {:ok, events} =
             reply(conn, ctx.owner, upstream, %{
               "body" => "Design answers.",
               "parts" => %{
                 "design" => %{
                   "body" => "Use these design answers.",
                   "parts" => %{
                     "logo" => %{"body" => "Use the blue logo."},
                     "tone" => %{"body" => "Use a calm tone."}
                   }
                 }
               }
             })

    assert Enum.count(events, &(&1.type == "reply")) == 4
    assert Enum.all?([logo, tone, merged, upstream], &(request(conn, &1).status == "closed"))
    for id <- ctx.children, do: assert(work(conn, id).state == "open")
    for id <- [ctx.root, ctx.lead], do: assert(work(conn, id).waiting == "child")
    assert {:ok, comments} = Store.comments(conn, :request, logo)
    assert Enum.map(comments, & &1.body) == ["logo", "Use the blue logo."]
    assert {:ok, comments} = Store.comments(conn, :request, tone)
    assert Enum.map(comments, & &1.body) == ["tone", "Use a calm tone."]

    assert Enum.all?(
             Enum.filter(events, &(&1.type == "reply")),
             &(&1.actor_kind == "human" and &1.actor_subject == "owner")
           )

    assert {:error, {:reply, :closed}} = reply(conn, ctx.owner, upstream, %{"body" => "Again."})
  end

  test "text returns origins to pending for distribution without replacing child waits",
       %{conn: conn} = ctx do
    {logo, tone, merged} = questions(conn, ctx)
    assert {:ok, _} = reply(conn, ctx.root_ctx, merged, %{"body" => "Blue logo; calm tone."})
    assert request(conn, merged).status == "closed"
    assert request(conn, logo).status == "pending"
    assert request(conn, tone).status == "pending"
    assert work(conn, ctx.lead).waiting == "child"
    assert {:ok, _} = reply(conn, ctx.lead_ctx, logo, %{"body" => "Blue logo."})
    assert work(conn, hd(ctx.children)).state == "open"
    assert work(conn, List.last(ctx.children)).state == "waiting"
    assert {:ok, _} = reply(conn, ctx.lead_ctx, tone, %{"body" => "Calm tone."})
  end

  test "partial named replies leave missing parts pending for another distribution round",
       %{conn: conn} = ctx do
    {logo, tone, merged} = questions(conn, ctx)

    assert {:ok, _} =
             reply(conn, ctx.root_ctx, merged, %{
               "body" => "Only the logo is known.",
               "parts" => %{"logo" => %{"body" => "Blue."}}
             })

    assert request(conn, logo).status == "closed"
    assert request(conn, tone).status == "pending"
    assert work(conn, List.last(ctx.children)).state == "waiting"
    assert {:ok, []} = Store.received_inbox(conn, ctx.root_ctx.run_id)
    again = escalate(conn, ctx.lead_ctx, %{"tone" => tone})
    assert {:ok, [%{requests: [%{id: ^again}]}]} = Store.received_inbox(conn, ctx.root_ctx.run_id)
    assert request(conn, again).origins["tone"].id == tone
    assert count(conn, "request_escalations") == 3
  end

  test "invalid named parts roll back replies, comments, statuses and work wakes",
       %{conn: conn} = ctx do
    {logo, tone, merged} = questions(conn, ctx)
    before = {count(conn, "events"), count(conn, "comments")}

    for parts <- [
          %{"missing" => %{"body" => "No."}},
          %{"logo" => %{"body" => "Blue."}, "tone" => %{"body" => ""}},
          %{"logo" => %{"body" => "Blue.", "option" => "unknown"}},
          %{"logo" => %{"body" => "Blue.", "parts" => %{"nested" => %{"body" => "No."}}}},
          %{"logo" => %{"body" => "Blue.", "parts" => nil}},
          %{"logo" => %{"body" => "Blue.", "parts" => []}},
          %{"logo" => %{"body" => "Blue.", "parts" => 42}},
          %{"logo" => %{"body" => "Blue.", "request_id" => tone}}
        ] do
      assert {:ok, false} =
               Omunculus.Store.Access.reply_needs_project_config?(
                 %Omunculus.Project{
                   conn: conn,
                   dir: ctx.config.root,
                   config_path: Path.join(ctx.config.root, "omunculus.toml")
                 },
                 merged,
                 %{"body" => "Answers.", "parts" => parts}
               )

      assert {:error, _} =
               reply(conn, ctx.root_ctx, merged, %{"body" => "Answers.", "parts" => parts})

      assert before == {count(conn, "events"), count(conn, "comments")}
      assert request(conn, merged).status == "pending"
      assert request(conn, logo).status == "escalated"
      assert request(conn, tone).status == "escalated"
      for id <- ctx.children, do: assert(work(conn, id).state == "waiting")
    end
  end

  test "only the receiver can merge pending distinct origins in the same conversation",
       %{conn: conn} = ctx do
    [first, second] = ctx.child_ctxs
    logo = ask(conn, first, "logo")
    tone = ask(conn, second, "tone")
    before = count(conn, "requests")

    for {actor, origins} <- [
          {ctx.root_ctx, %{"logo" => logo}},
          {ctx.lead_ctx, %{"one" => logo, "two" => logo}},
          {ctx.lead_ctx, %{}},
          {ctx.lead_ctx, %{"" => logo}}
        ] do
      assert {:error, _} =
               apply_action(
                 conn,
                 "escalate",
                 %{"reason" => "Questions.", "origins" => origins},
                 actor
               )

      assert count(conn, "requests") == before
    end

    merged = escalate(conn, ctx.lead_ctx, %{"logo" => logo})

    assert {:error, _} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Again.", "origins" => %{"logo" => logo}},
               ctx.lead_ctx
             )

    assert {:error, {:reply, :escalated}} =
             reply(conn, ctx.lead_ctx, logo, %{"body" => "Too soon."})

    assert {:ok, _} = reply(conn, ctx.lead_ctx, tone, %{"body" => "Calm."})

    assert {:error, _} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Closed.", "origins" => %{"tone" => tone}},
               ctx.lead_ctx
             )

    assert request(conn, merged).status == "pending"
  end

  test "cross-conversation merge is refused even when agent identities match",
       %{conn: conn} = ctx do
    logo = ask(conn, hd(ctx.child_ctxs), "logo")
    other = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: other,
        created_issuer: "test",
        created_subject: "owner",
        created_at: "2026-01-01"
      })

    other_root = Fixtures.insert(conn, :works, %{assignee: "root", conversation_id: other})

    other_lead =
      Fixtures.insert(conn, :works, %{
        assignee: "lead",
        parent_id: other_root,
        conversation_id: other
      })

    other_child =
      Fixtures.insert(conn, :works, %{
        assignee: "worker",
        parent_id: other_lead,
        conversation_id: other
      })

    tone = ask(conn, context(conn, ctx.config, other_child, "worker", 2, other), "tone")
    before = count(conn, "requests")

    assert {:error, {:escalate, :invalid_origin}} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Mixed clients.", "origins" => %{"logo" => logo, "tone" => tone}},
               ctx.lead_ctx
             )

    assert count(conn, "requests") == before
    assert request(conn, logo).status == "pending"
    assert request(conn, tone).status == "pending"
  end

  test "a human origin and an agent origin can be merged without inventing a human run",
       %{conn: conn} = ctx do
    client = human_origin(conn, ctx, "client")
    human_request = ask(conn, client, "What is the budget?")
    {logo, _tone, merged} = questions(conn, ctx)
    upstream = escalate(conn, ctx.root_ctx, %{"client" => human_request, "team" => merged})
    assert is_nil(request(conn, human_request).run_id)
    assert Jason.decode!(request(conn, upstream).arbiter) == Participant.human("test", "owner")

    assert {:ok, _} =
             reply(conn, ctx.owner, upstream, %{
               "body" => "Answers.",
               "parts" => %{
                 "client" => %{"body" => "The budget is 100."},
                 "team" => %{"body" => "Blue logo.", "parts" => %{"logo" => %{"body" => "Blue."}}}
               }
             })

    assert request(conn, human_request).status == "closed"
    assert request(conn, logo).status == "closed"
  end

  test "a human receiver can escalate to an agent without a synthetic run", %{conn: conn} = ctx do
    config =
      Fixtures.config(
        @agents <>
          """
          [policy]
          request_routes = [
            { from = { kind = "agent", agent = "worker" }, via = ["origin"] },
            { via = ["parent", "origin"] }
          ]
          """
      )

    ctx = %{
      ctx
      | config: config,
        owner: %{ctx.owner | config: config},
        child_ctxs: Enum.map(ctx.child_ctxs, &%{&1 | config: config})
    }

    origin =
      ask(conn, hd(ctx.child_ctxs), "Deploy?", %{
        "grant" => [%{"name" => "grant", "args" => %{"kind" => "tool", "name" => "deploy"}}]
      })

    reviewer = Map.put(ctx.owner, :work_id, ctx.lead)

    assert {:error, {:escalate, :invalid_origin}} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Deploy?", "origins" => %{"deployment" => origin}},
               ctx.root_ctx
             )

    upstream = escalate(conn, reviewer, %{"deployment" => origin})
    assert is_nil(request(conn, upstream).run_id)

    assert {:ok, _} =
             reply(conn, ctx.owner, upstream, %{
               "body" => "Not now",
               "parts" => %{"deployment" => %{"body" => "Not now"}}
             })

    assert request(conn, origin).status == "closed"
  end

  test "a receiver cannot route an escalation back into its linked origins",
       %{conn: conn} = ctx do
    client = human_origin(conn, ctx, "owner")
    origin = ask(conn, client, "Budget?")

    assert {:error, {:request, :no_route}} =
             apply_action(
               conn,
               "escalate",
               %{"reason" => "Budget?", "origins" => %{"budget" => origin}},
               ctx.root_ctx
             )

    assert request(conn, origin).status == "pending"
    assert count(conn, "request_escalations") == 0
  end

  test "opening events preserve the workflow and stage at the time of asking",
       %{conn: conn} = ctx do
    [actor | _] = ctx.child_ctxs

    :ok =
      Query.exec(conn, "UPDATE works SET workflow = 'design', stage = 'draft' WHERE id = ?", [
        actor.work_id
      ])

    id = ask(conn, actor, "Logo?")
    :ok = Query.exec(conn, "UPDATE works SET stage = 'build' WHERE id = ?", [actor.work_id])
    {:ok, event} = View.view(conn, "event", request(conn, id).event_id)
    assert Jason.decode!(event.body)["workflow"] == "design"
    assert Jason.decode!(event.body)["stage"] == "draft"
  end

  test "real cycles pause escalation and resume intermediaries still waiting for children",
       %{conn: conn} = ctx do
    [logo, tone] = Enum.zip_with(ctx.child_ctxs, ~w(logo tone), &ask(conn, &1, &2))

    for actor <- [ctx.root_ctx, ctx.lead_ctx | ctx.child_ctxs],
        do: assert({:ok, _} = Store.close_run(conn, actor.run_id))

    {:ok, turns} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(turns), do: Agent.stop(turns) end)

    received = fn agent ->
      {:ok, [%{id: id}]} =
        Query.all(
          conn,
          "SELECT id FROM requests WHERE status = 'pending' AND json_extract(arbiter, '$.agent') = ?",
          [agent]
        )

      id
    end

    Fixtures.use_model(ctx.config.root, fn assembled, _tools, call ->
      role = Fixtures.role(assembled)

      turn =
        Agent.get_and_update(turns, fn counts ->
          n = Map.get(counts, role, 0) + 1
          {n, Map.put(counts, role, n)}
        end)

      case {role, turn} do
        {"lead", 1} ->
          call.("escalate", %{
            "reason" => "Choose logo and tone",
            "origins" => %{"logo" => logo, "tone" => tone}
          })

        {"root", 1} ->
          call.("escalate", %{
            "reason" => "Design question",
            "origins" => %{"design" => received.("root")}
          })

        {"root", 2} ->
          assert assembled =~ "Use blue and calm."
          assert assembled =~ "design"
          call.("reply", %{"request_id" => received.("root"), "body" => "Use blue and calm."})
          call.("end", %{})

        {"lead", 2} ->
          assert assembled =~ "Use blue and calm."

          for {id, text} <- [{logo, "Blue logo."}, {tone, "Calm tone."}],
              do: call.("reply", %{"request_id" => id, "body" => text})

          call.("end", %{})

        {"worker", _} ->
          call.("end", %{})

        other ->
          flunk("unexpected resumed role: #{inspect(other)}")
      end
    end)

    project = %Omunculus.Project{conn: conn, dir: ctx.config.root, config_path: ctx.config.path}

    events =
      Enum.map([logo, tone], fn id ->
        {:ok, event} = Store.view(conn, "event", request(conn, id).event_id)
        event
      end)

    assert :ok = Omunculus.Harness.follow_up(project, events)
    assert Agent.get(turns, & &1) == %{"lead" => 1, "root" => 1}

    {:ok, [%{id: upstream}]} =
      Query.all(
        conn,
        "SELECT id FROM requests WHERE status = 'pending' AND json_extract(arbiter, '$.kind') = 'human'"
      )

    assert {:ok, answer_events} =
             reply(conn, ctx.owner, upstream, %{"body" => "Use blue and calm."})

    assert :ok = Omunculus.Harness.follow_up(project, answer_events)
    assert Agent.get(turns, & &1) == %{"lead" => 2, "root" => 2, "worker" => 2}
    assert work(conn, ctx.root).waiting == "child"
    assert work(conn, ctx.lead).waiting == "child"
    assert Enum.all?(ctx.children, &(work(conn, &1).state == "open"))
    assert {:ok, []} = Query.all(conn, "SELECT id FROM requests WHERE status != 'closed'")

    assert {:ok, runs} =
             Query.all(
               conn,
               "SELECT r.agent, e.type FROM runs r JOIN events e ON e.id = r.cause_id ORDER BY r.started_at"
             )

    assert Enum.count(runs, &(&1.type == "request")) == 2
    assert Enum.count(runs, &(&1.type == "reply")) == 4
  end

  test "sealed promote climbs two receivers and grants only the original work with human authority",
       %{conn: conn} = ctx do
    [child | _] = ctx.child_ctxs

    options = %{
      "grant" => [%{"name" => "grant", "args" => %{"name" => "promote", "kind" => "tool"}}]
    }

    origin = ask(conn, child, "Deploy permission", options)
    upstream = escalate(conn, ctx.lead_ctx, %{"permission" => origin})
    top = escalate(conn, ctx.root_ctx, %{"release" => upstream})
    assert Jason.decode!(request(conn, origin).arbiter) == Participant.agent("lead")
    assert Jason.decode!(request(conn, upstream).arbiter) == Participant.agent("root")
    assert Jason.decode!(request(conn, top).arbiter) == Participant.human("test", "owner")
    project = %Omunculus.Project{conn: conn, dir: ctx.config.root, config_path: ctx.config.path}

    answer = %{
      "request_id" => upstream,
      "body" => "Permission",
      "parts" => %{"permission" => %{"body" => "Yes", "option" => "grant"}}
    }

    agent = Map.put(ctx.root_ctx, :trigger, "model")
    assert {:ok, %{ok: false}, _} = Omunculus.Harness.dispatch(project, "reply", answer, agent)
    assert request(conn, origin).status == "escalated"
    assert work(conn, child.work_id).grants == nil
    human = Map.put(ctx.owner, :trigger, "cli")

    answer = %{
      "request_id" => top,
      "body" => "Production approved",
      "parts" => %{"release" => Map.take(answer, ["body", "parts"])}
    }

    assert {:ok, %{ok: true}, events} =
             Omunculus.Harness.dispatch(project, "reply", answer, human)

    grant = Enum.find(events, &(&1.type == "grant"))
    assert grant.work_id == child.work_id
    assert grant.request_id == origin
    assert grant.actor_kind == "human"
    assert Jason.decode!(work(conn, child.work_id).grants) == ["promote"]
    assert work(conn, ctx.lead).grants == nil
    assert work(conn, ctx.root).grants == nil
  end

  test "concurrent reply versus escalation commits exactly one outcome", %{conn: conn} = ctx do
    origin = ask(conn, hd(ctx.child_ctxs), "Logo?")
    parent = self()

    calls = [
      fn -> reply(conn, ctx.lead_ctx, origin, %{"body" => "Blue."}) end,
      fn ->
        apply_action(
          conn,
          "escalate",
          %{"reason" => "Logo?", "origins" => %{"logo" => origin}},
          ctx.lead_ctx
        )
      end
    ]

    tasks =
      Enum.map(calls, fn action ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> action.()
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    status = request(conn, origin).status
    assert status in ~w(closed escalated)
    assert count(conn, "request_escalations") == if(status == "escalated", do: 1, else: 0)
  end

  test "a named answer cannot reopen an origin work cancelled during escalation",
       %{conn: conn} = ctx do
    [child | _] = ctx.child_ctxs
    origin = ask(conn, child, "Logo?")
    upstream = escalate(conn, ctx.lead_ctx, %{"logo" => origin})
    assert {:ok, _} = apply_action(conn, "cancel", %{"request_id" => origin}, ctx.owner)

    assert {:ok, events} =
             reply(conn, ctx.root_ctx, upstream, %{
               "body" => "Blue",
               "parts" => %{"logo" => %{"body" => "Blue"}}
             })

    Fixtures.use_model(ctx.config.root, fn _, _, _ -> flunk("cancelled work must not resume") end)
    project = %Omunculus.Project{conn: conn, dir: ctx.config.root, config_path: ctx.config.path}
    assert :ok = Omunculus.Harness.follow_up(project, events)
    assert work(conn, child.work_id).state == "cancelled"
    assert request(conn, origin).status == "closed"
  end

  test "eval choices answer a nested merge with original grants and decisions",
       %{conn: conn} = ctx do
    [first, second] = ctx.child_ctxs

    permission =
      ask(conn, first, "Write?", %{
        "grant" => [%{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write"}}],
        "deny" => []
      })

    decision = ask(conn, second, "Approve?", %{"approve" => [], "deny" => []})
    merged = escalate(conn, ctx.lead_ctx, %{"permission" => permission, "decision" => decision})
    upstream = escalate(conn, ctx.root_ctx, %{"design" => merged})
    request = request(conn, upstream)
    task = %{human: %{"fs.write" => "grant", "decision" => "approve"}}

    answer =
      EquivalentExchange.Requests.choose(
        task,
        %{"fs.write" => ["write"]},
        request,
        ctx.config.root
      )

    assert answer["parts"]["design"]["parts"]["permission"]["option"] == "grant"
    assert answer["parts"]["design"]["parts"]["decision"]["option"] == "approve"
    arguments = EquivalentExchange.Requests.arguments(ctx.config.path, upstream, answer)
    assert ["--parts", encoded] = Enum.take(arguments, -2)
    project = %Omunculus.Project{conn: conn, dir: ctx.config.root, config_path: ctx.config.path}
    args = %{"request_id" => upstream, "body" => answer["body"], "parts" => encoded}

    assert {:ok, %{ok: true}, _} =
             Omunculus.Harness.dispatch(
               project,
               "reply",
               args,
               Map.put(ctx.owner, :trigger, "cli")
             )

    assert Jason.decode!(work(conn, first.work_id).grants) == ["write"]
    assert request(conn, decision).answer == "approve"
    records = EquivalentExchange.Requests.answers(request, answer)
    assert Enum.find(records, &(&1.request == permission)).option == "grant"
    assert Enum.find(records, &(&1.request == decision)).option == "approve"

    assert Enum.all?(
             [permission, decision, merged, upstream],
             &(request(conn, &1).status == "closed")
           )
  end

  test "eval denies forbidden grants and leaves retry-only parts unanswered",
       %{conn: conn} = ctx do
    [first, second] = ctx.child_ctxs

    permission =
      ask(conn, first, "Write?", %{
        "grant" => [%{"name" => "grant", "args" => %{"kind" => "tool", "name" => "write"}}],
        "deny" => []
      })

    retry = ask(conn, second, "Retry?", %{"retry" => [], "cancel" => [%{"name" => "cancel"}]})
    merged = escalate(conn, ctx.lead_ctx, %{"permission" => permission, "retry" => retry})
    task = %{human: %{}}
    answer = EquivalentExchange.Requests.choose(task, %{}, request(conn, merged), ctx.config.root)
    assert answer["parts"]["permission"]["option"] == "deny"
    refute Map.has_key?(answer["parts"], "retry")

    assert is_nil(
             EquivalentExchange.Requests.choose(task, %{}, request(conn, retry), ctx.config.root)
           )

    assert {:ok, _} = reply(conn, ctx.root_ctx, merged, answer)
    assert request(conn, permission).status == "closed"
    assert request(conn, retry).status == "pending"
    assert work(conn, first.work_id).grants == nil
  end

  test "amestris configures routes for decisions, permissions and root retry exhaustion", %{
    conn: conn
  } do
    {:ok, config} =
      Omunculus.Config.load(Path.expand("../../../eval/presets/amestris/omunculus.toml", __DIR__))

    assert config.request_routes == [%{"via" => ["parent", "origin"]}]

    run =
      Fixtures.open_run(conn, %{
        agent: "father",
        ceiling: %{
          have: ["ask", "request_access", "end"],
          askable: ["write"],
          sealed: [],
          blocked: [],
          uncited: "askable"
        }
      })

    ctx = %{
      run_id: run.id,
      work_id: nil,
      agent: "father",
      author: "agent",
      config: config,
      groups: %{}
    }

    for options <- [
          %{"approve" => [], "deny" => []},
          %{
            "grant" => [%{"name" => "grant", "args" => %{"name" => "write", "kind" => "tool"}}],
            "deny" => []
          }
        ] do
      id = ask(conn, ctx, "Needs a response", options)
      assert request(conn, id).status == "pending"
      assert Jason.decode!(request(conn, id).arbiter)["kind"] == "human"
    end

    root = Fixtures.insert(conn, :works, %{assignee: "father"})
    stopped = Fixtures.open_run(conn, %{agent: "father", work_id: root})
    assert {:ok, _} = Store.close_run(conn, stopped.id)

    assert {:ok, {:stopped, [retry, _notification]}} =
             Store.unreported(
               conn,
               stopped,
               0,
               &Omunculus.Tools.Out.unreported/1,
               &Omunculus.Tools.Out.request_inbox/3,
               config
             )

    assert request(conn, retry.request_id).status == "pending"

    assert Jason.decode!(request(conn, retry.request_id).options) |> Map.keys() |> Enum.sort() ==
             ~w(cancel retry)
  end

  test "unanswered receivers escalate through parents and notify the human exactly once",
       %{conn: conn} = ctx do
    origin = ask(conn, hd(ctx.child_ctxs), "Logo?")

    incoming = fn agent, work_id, depth, request_id ->
      run =
        Fixtures.open_run(conn, %{
          agent: agent,
          work_id: work_id,
          depth: depth,
          conversation_id: ctx.conversation,
          request_id: request_id
        })

      {:ok, _} = Store.close_run(conn, run.id)
      {:ok, closed} = Store.view(conn, "run", run.id)
      closed
    end

    lead_run = incoming.("lead", ctx.lead, 1, origin)

    assert {:ok, first_events} =
             Store.unanswered(conn, lead_run, ctx.config, &Omunculus.Tools.Out.unanswered/3)

    merged = Enum.find(first_events, &(&1.type == "request")).request_id
    assert request(conn, origin).status == "escalated"
    assert Jason.decode!(request(conn, origin).arbiter) == Participant.agent("lead")
    assert Jason.decode!(request(conn, merged).arbiter) == Participant.agent("root")
    assert count(conn, "inbox") == 0
    root_run = incoming.("root", ctx.root, 0, merged)

    assert {:ok, last_events} =
             Store.unanswered(conn, root_run, ctx.config, &Omunculus.Tools.Out.unanswered/3)

    upstream = Enum.find(last_events, &(&1.type == "request")).request_id
    assert Jason.decode!(request(conn, upstream).arbiter) == Participant.human("test", "owner")
    assert count(conn, "inbox") == 1
    assert Enum.any?(last_events, &(&1.type == "notify"))
    assert {:ok, [note]} = Query.all(conn, "SELECT body FROM comments WHERE inbox_id IS NOT NULL")

    assert note.body ==
             "root left request #{merged} unresolved. Reply to linked request #{upstream}."

    assert {:ok, []} =
             Store.unanswered(conn, root_run, ctx.config, &Omunculus.Tools.Out.unanswered/3)

    assert {:ok, []} =
             Store.unanswered(conn, lead_run, ctx.config, &Omunculus.Tools.Out.unanswered/3)

    assert count(conn, "request_escalations") == 2
    assert count(conn, "inbox") == 1
    assert work(conn, ctx.root).waiting == "child"
    assert work(conn, ctx.lead).waiting == "child"
  end

  test "received inbox shows both root requests with canonical origins and isolates the run",
       %{conn: conn} = ctx do
    [first, second] = ctx.child_ctxs
    logo = ask(conn, first, "Which logo?")
    tone = ask(conn, second, "Which tone?")
    left = escalate(conn, ctx.lead_ctx, %{"logo" => logo})
    right = escalate(conn, ctx.lead_ctx, %{"tone" => tone})
    views = %{"inbox" => %{"source" => "inbox", "relation" => "received"}}
    {:ok, specs} = Omunculus.Tool.Views.parse(views)
    scope = %{run_id: ctx.root_ctx.run_id}
    before = {count(conn, "events"), count(conn, "comments")}

    assert {:ok, %{"inbox" => [group]}} = Omunculus.Tool.Views.hydrate(conn, specs, scope)
    assert group.conversation_id == ctx.conversation
    assert MapSet.new(group.requests, & &1.id) == MapSet.new([left, right])
    assert Enum.all?(group.requests, &(&1.status == "pending"))
    by_id = Map.new(group.requests, &{&1.id, &1})
    assert by_id[left].reason == "Answer these named questions."
    assert by_id[left].work_id == ctx.lead
    assert by_id[left].origins["logo"].id == logo
    assert by_id[left].origins["logo"].work_id == first.work_id
    assert by_id[left].origins["logo"].reason == "Which logo?"
    assert by_id[right].origins["tone"].reason == "Which tone?"
    assert before == {count(conn, "events"), count(conn, "comments")}

    workless =
      Fixtures.open_run(conn, %{agent: "root", depth: 0, conversation_id: ctx.conversation})

    assert {:ok, %{"inbox" => [same]}} =
             Omunculus.Tool.Views.hydrate(conn, specs, %{run_id: workless.id})

    assert MapSet.new(same.requests, & &1.id) == MapSet.new([left, right])

    for fields <- [
          %{agent: "steward", depth: 0, conversation_id: ctx.conversation},
          %{agent: "root", depth: 1, conversation_id: ctx.conversation},
          %{agent: "root", depth: 0, conversation_id: nil}
        ] do
      run = Fixtures.open_run(conn, fields)

      assert {:ok, %{"inbox" => []}} =
               Omunculus.Tool.Views.hydrate(conn, specs, %{run_id: run.id})
    end

    other = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: other,
        created_issuer: "test",
        created_subject: "other",
        created_at: "2026-01-01"
      })

    run = Fixtures.open_run(conn, %{agent: "root", depth: 0, conversation_id: other})
    assert {:ok, %{"inbox" => []}} = Omunculus.Tool.Views.hydrate(conn, specs, %{run_id: run.id})
    assert {:ok, %{}} = Omunculus.Tool.Views.hydrate(conn, specs, %{run_id: nil})

    assert {:ok, _} =
             reply(conn, ctx.root_ctx, left, %{
               "body" => "Logo attached",
               "parts" => %{"logo" => %{"body" => "Use this logo"}}
             })

    assert {:ok, [remaining]} = Store.received_inbox(conn, ctx.root_ctx.run_id)
    assert Enum.map(remaining.requests, & &1.id) == [right]
    assert request(conn, tone).status == "escalated"
    assert work(conn, second.work_id).waiting == "request"
    _upstream = escalate(conn, ctx.root_ctx, %{"tone" => right})
    assert {:ok, []} = Store.received_inbox(conn, ctx.root_ctx.run_id)
  end

  test "reading a notice does not hide independent requests, including a human origin",
       %{conn: conn} = ctx do
    human = human_origin(conn, ctx, "client")
    human_id = ask(conn, human, "Is the schedule available?")
    child = hd(ctx.child_ctxs)
    origin = ask(conn, child, "Which logo?")
    agent_id = escalate(conn, ctx.lead_ctx, %{"logo" => origin})

    assert {:ok, events} =
             apply_action(conn, "notify", %{"body" => "Questions ready"}, ctx.lead_ctx)

    note = Enum.find(events, &(&1.type == "notify")).inbox_id
    assert {:ok, _} = apply_action(conn, "inbox.read", %{"inbox_id" => note}, ctx.owner)
    assert {:ok, []} = Store.unread_inbox(conn, ctx.lead)

    assert {:ok, [group]} = Store.received_inbox(conn, ctx.root_ctx.run_id)
    assert MapSet.new(group.requests, & &1.id) == MapSet.new([human_id, agent_id])
    received = Enum.find(group.requests, &(&1.id == human_id))
    assert received.run_id == nil
    assert Jason.decode!(received.requester) == Participant.human("test", "client")
    assert received.reason == "Is the schedule available?"
    assert {:ok, _} = reply(conn, ctx.root_ctx, human_id, %{"body" => "Yes, it is available."})
    assert {:ok, [remaining]} = Store.received_inbox(conn, ctx.root_ctx.run_id)
    assert Enum.map(remaining.requests, & &1.id) == [agent_id]
    assert request(conn, origin).status == "escalated"
    assert work(conn, child.work_id).waiting == "request"
  end

  test "the builtin assemble hydrates both received requests from two works",
       %{conn: conn} = ctx do
    [first, second] = ctx.child_ctxs
    logo = ask(conn, first, "Which logo?")
    tone = ask(conn, second, "Which tone?")
    left = escalate(conn, ctx.lead_ctx, %{"logo" => logo})
    right = escalate(conn, ctx.lead_ctx, %{"tone" => tone})
    project = %Omunculus.Project{conn: conn, dir: ctx.config.root, config_path: ctx.config.path}
    actor = Map.put(ctx.root_ctx, :trigger, "harness")

    assert {:ok, out, _events} =
             Omunculus.Harness.dispatch(
               project,
               "assemble",
               %{"text" => "Collect the client questions.", "agent" => "root"},
               actor
             )

    assert out.ok
    assert out.output =~ "## Inbox\n### Conversation #{ctx.conversation}"

    for id <- [left, right, logo, tone, first.work_id, second.work_id] do
      assert out.output =~ id
    end

    assert out.output =~ "Which logo?"
    assert out.output =~ "Which tone?"
    assert request(conn, left).status == "pending"
    assert request(conn, right).status == "pending"
  end
end
