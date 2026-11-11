defmodule Omunculus.Store.RequestRoutesTest do
  use Omunculus.StoreCase, async: true
  alias Omunculus.{Fixtures, Id, Participant, Store}
  alias Omunculus.Store.Query

  test "unknown route refusals list configured names and explain the default route", %{conn: conn} do
    for {routes, names, label} <- [
          {[%{"via" => ["origin"]}], [], "none"},
          {[%{"name" => "owner"}, %{"name" => "legal"}, %{"name" => "owner"}, %{}],
           ["legal", "owner"], "legal, owner"}
        ] do
      assert {:error, reason} =
               Omunculus.Store.RequestRoutes.resolve(
                 conn,
                 %{config: %{request_routes: routes}},
                 nil,
                 nil,
                 Participant.agent("sales"),
                 "client",
                 []
               )

      assert reason == {:request, {:unknown_route, "client", names}}

      assert Omunculus.Tools.Out.refused(reason) ==
               ~s(refused: "client" is not a configured request route; configured route names: #{label}; omit to to follow the default request_routes route)
    end
  end

  test "a workless route cannot deliver to a workflow-only agent", %{conn: conn} do
    config =
      Fixtures.config("""
      [agents.stage]
      depth = 0
      workflow_only = true
      text = "stage"
      [policy]
      request_routes = [
        { name = "stage", via = [{ kind = "agent", agent = "stage" }] },
        { name = "next", via = [{ kind = "agent", agent = "stage" }, "origin"] }
      ]
      """)

    conversation = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: conversation,
        created_issuer: "test",
        created_subject: "owner",
        created_at: "2026-01-01"
      })

    ctx = %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "test",
      subject: "client",
      config: config,
      groups: %{},
      conversation_id: conversation
    }

    request = fn route ->
      body = %{"reason" => "Question", "options" => %{}, "to" => route}

      Store.record_tools(
        conn,
        nil,
        [{%{name: "ask", args: %{}}, [%{"type" => "request", "body" => body}]}],
        ctx
      )
    end

    assert {:error, {:request, :no_route}} = request.("stage")
    assert {:ok, []} = Query.all(conn, "SELECT id FROM requests")
    assert {:ok, [_tool, event]} = request.("next")
    assert {:ok, row} = Store.view(conn, "request", event.request_id)
    assert Jason.decode!(row.arbiter) == Participant.human("test", "owner")
  end

  describe "escalation scope" do
    @scoped """
    [agents.lead]
    depth = 0
    text = "lead"
    [agents.worker]
    depth = 1
    text = "worker"
    [access]
    creator_role = "participant"
    bootstrap_role = "admin"
    [access.roles.admin]
    scope = "project"
    capabilities = ["project.manage_access", "project.manage_config", "project.own", "conversation.read", "conversation.reply"]
    [access.roles.participant]
    scope = "conversation"
    capabilities = ["conversation.read", "conversation.manage_access"]
    [workflows.release]
    steps = [{ name = "promote", agent = "worker" }]
    [policy]
    request_routes = [
      { workflow = "release", stage = "promote", via = [{ kind = "agent", agent = "lead" }, "owners"] },
      { via = [{ kind = "agent", agent = "lead" }, "origin"] }
    ]
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

      :ok =
        Query.insert(conn, :project_members, %{
          issuer: "test",
          subject: "boss",
          role: "admin",
          updated_at: "2026-01-01"
        })

      ctx = %{config: Fixtures.config(@scoped), conversation_id: conversation}
      %{ctx: ctx}
    end

    defp route(conn, ctx, opts) do
      Omunculus.Store.RequestRoutes.resolve(
        conn,
        ctx,
        nil,
        nil,
        Participant.agent("lead"),
        nil,
        [],
        opts
      )
    end

    test "an escalation matches the rules of its origins' workflow and stage", %{
      conn: conn,
      ctx: ctx
    } do
      assert {:ok, %{"kind" => "human", "subject" => "boss"}, nil, "owners"} =
               route(conn, ctx, scope: {"release", "promote"})

      assert {:ok, %{"subject" => "client"}, nil, "origin"} = route(conn, ctx, [])
    end
  end

  describe "escalation route" do
    @hub """
    [agents.lead]
    depth = 0
    text = "lead"
    [agents.hub]
    depth = 0
    text = "hub"
    [agents.worker]
    depth = 1
    text = "worker"
    [access]
    creator_role = "participant"
    bootstrap_role = "admin"
    [access.roles.admin]
    scope = "project"
    capabilities = ["project.manage_access", "project.manage_config", "project.own", "conversation.read", "conversation.reply"]
    [access.roles.participant]
    scope = "conversation"
    capabilities = ["conversation.read", "conversation.manage_access"]
    [policy]
    request_routes = [
      { name = "owner", via = [{ kind = "agent", agent = "hub" }, "owners"] },
      { name = "client", via = ["origin"] },
      { via = [{ kind = "agent", agent = "hub" }, "origin"] }
    ]
    """

    setup %{conn: conn} do
      config = Fixtures.config(@hub)
      conversation = Id.new()

      :ok =
        Query.insert(conn, :conversations, %{
          id: conversation,
          created_issuer: "test",
          created_subject: "client",
          created_at: "2026-01-01"
        })

      :ok =
        Query.insert(conn, :project_members, %{
          issuer: "test",
          subject: "boss",
          role: "admin",
          updated_at: "2026-01-01"
        })

      ctx = fn agent, parent ->
        work =
          Fixtures.insert(conn, :works, %{
            assignee: agent,
            parent_id: parent,
            conversation_id: conversation
          })

        run =
          Fixtures.open_run(conn, %{
            agent: agent,
            depth: 0,
            work_id: work,
            conversation_id: conversation
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

      %{hub: ctx.("hub", nil), worker: ctx.("worker", nil), conversation: conversation}
    end

    defp put(conn, ctx, type, body) do
      with {:ok, events} <-
             Store.record_tools(
               conn,
               ctx.run_id,
               [{%{name: type, args: %{}}, [%{"type" => type, "body" => body}]}],
               ctx
             ) do
        Store.view(conn, "request", Enum.find(events, &(&1.type == "request")).request_id)
      end
    end

    defp ask_on(conn, ctx, route) do
      body = %{"reason" => "Approve?", "options" => %{}}
      put(conn, ctx, "request", if(route, do: Map.put(body, "to", route), else: body))
    end

    defp pass_up(conn, ctx, origin, route) do
      body = %{"reason" => "Decide?", "origins" => %{"q" => origin.id}}
      put(conn, ctx, "escalate", if(route, do: Map.put(body, "to", route), else: body))
    end

    test "an owner-route request escalated without to goes on to the owners", %{
      conn: conn,
      hub: hub,
      worker: worker
    } do
      assert {:ok, asked} = ask_on(conn, worker, "owner")
      assert Jason.decode!(asked.arbiter) == Participant.agent("hub")

      assert {:ok, up} = pass_up(conn, hub, asked, nil)
      assert Jason.decode!(up.arbiter) == Participant.human("test", "boss")
      assert {up.route, up.destination} == {"owner", "owners"}
    end

    test "a default-route request escalated without to follows the default route", %{
      conn: conn,
      hub: hub,
      worker: worker
    } do
      assert {:ok, asked} = ask_on(conn, worker, nil)
      assert {:ok, up} = pass_up(conn, hub, asked, nil)
      assert Jason.decode!(up.arbiter) == Participant.human("test", "client")
      assert {up.route, up.destination} == {nil, "origin"}
    end

    test "an explicit to wins over the route of the origins", %{
      conn: conn,
      hub: hub,
      worker: worker
    } do
      assert {:ok, asked} = ask_on(conn, worker, "owner")
      assert {:ok, up} = pass_up(conn, hub, asked, "client")
      assert Jason.decode!(up.arbiter) == Participant.human("test", "client")
      assert {up.route, up.destination} == {"client", "origin"}
    end

    test "an unanswered receiver passes a named-route request along its route", %{
      conn: conn,
      hub: hub,
      worker: worker
    } do
      assert {:ok, asked} = ask_on(conn, worker, "owner")

      run =
        Fixtures.open_run(conn, %{
          agent: "hub",
          work_id: hub.work_id,
          depth: 0,
          conversation_id: hub.conversation_id,
          request_id: asked.id
        })

      {:ok, _} = Store.close_run(conn, run.id)
      {:ok, closed} = Store.view(conn, "run", run.id)

      assert {:ok, events} =
               Store.unanswered(conn, closed, hub.config, &Omunculus.Tools.Out.unanswered/3)

      upstream = Enum.find(events, &(&1.type == "request")).request_id
      assert {:ok, up} = Store.view(conn, "request", upstream)
      assert Jason.decode!(up.arbiter) == Participant.human("test", "boss")
      assert {up.route, up.destination} == {"owner", "owners"}
    end
  end

  describe "client and owner" do
    @owners """
    [agents.lead]
    depth = 0
    text = "lead"
    [agents.worker]
    depth = 1
    text = "worker"
    [access]
    creator_role = "participant"
    bootstrap_role = "admin"
    [access.roles.admin]
    scope = "project"
    capabilities = ["project.manage_access", "project.manage_config", "project.own", "conversation.read", "conversation.reply"]
    [access.roles.participant]
    scope = "conversation"
    capabilities = ["conversation.read", "conversation.manage_access"]
    [policy]
    max_reopens = 0
    harness_route = "owner"
    request_routes = [
      { name = "owner", via = ["owners"] },
      { name = "either", via = ["owners", "origin"] },
      { via = ["parent", "origin"] }
    ]
    """

    defp owners_setup(conn, owners, client \\ "client") do
      config = Fixtures.config(@owners)
      conversation = Id.new()

      :ok =
        Query.insert(conn, :conversations, %{
          id: conversation,
          created_issuer: "test",
          created_subject: client,
          created_at: "2026-01-01"
        })

      for {subject, role, at} <- owners,
          do:
            Query.insert(conn, :project_members, %{
              issuer: "test",
              subject: subject,
              role: role,
              updated_at: at
            })

      lead = Fixtures.insert(conn, :works, %{assignee: "lead", conversation_id: conversation})

      worker =
        Fixtures.insert(conn, :works, %{
          assignee: "worker",
          parent_id: lead,
          conversation_id: conversation
        })

      ctx = fn work, agent ->
        run =
          Fixtures.open_run(conn, %{
            agent: agent,
            depth: 0,
            work_id: work,
            conversation_id: conversation
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

      %{lead: ctx.(lead, "lead"), worker: ctx.(worker, "worker")}
    end

    defp ask(conn, ctx, route) do
      body = %{"reason" => "Approve?", "options" => %{}}
      body = if route, do: Map.put(body, "to", route), else: body

      with {:ok, [_tool, event]} <-
             Store.record_tools(
               conn,
               ctx.run_id,
               [{%{name: "ask", args: %{}}, [%{"type" => "request", "body" => body}]}],
               ctx
             ) do
        Store.view(conn, "request", event.request_id)
      end
    end

    test "owners and the client are different arbiters, each recorded", %{conn: conn} do
      ctxs = owners_setup(conn, [{"boss", "admin", "2026-01-01"}])

      assert {:ok, owner} = ask(conn, ctxs.worker, "owner")
      assert Jason.decode!(owner.arbiter) == Participant.human("test", "boss")
      assert {owner.route, owner.destination} == {"owner", "owners"}

      assert {:ok, client} = ask(conn, ctxs.lead, nil)
      assert Jason.decode!(client.arbiter) == Participant.human("test", "client")
      assert {client.route, client.destination} == {nil, "origin"}
    end

    test "a reopen past max_reopens asks the owners, never the client", %{conn: conn} do
      ctxs = owners_setup(conn, [{"boss", "admin", "2026-01-01"}])

      child =
        Fixtures.insert(conn, :works, %{
          assignee: "worker",
          parent_id: ctxs.worker.work_id,
          state: "waiting",
          conversation_id: ctxs.worker.conversation_id
        })

      emit = %{
        "type" => "reopen",
        "body" => %{"work_id" => child, "body" => "again", "past_limit" => "it keeps breaking"}
      }

      assert {:ok, [_tool, %{type: "request"} = event]} =
               Store.record_tools(
                 conn,
                 ctxs.worker.run_id,
                 [{%{name: "reopen", args: %{}}, [emit]}],
                 ctxs.worker
               )

      assert {:ok, request} = Store.view(conn, "request", event.request_id)
      assert Jason.decode!(request.arbiter) == Participant.human("test", "boss")
      assert {request.route, request.destination} == {"owner", "owners"}
    end

    test "the owner added first takes it, whatever the update times", %{conn: conn} do
      ctxs =
        owners_setup(conn, [
          {"first", "admin", "2026-03-01"},
          {"late", "admin", "2026-01-01"},
          {"reader", "participant", "2025-01-01"}
        ])

      assert {:ok, request} = ask(conn, ctxs.worker, "owner")
      assert Jason.decode!(request.arbiter) == Participant.human("test", "first")
    end

    test "a project without owners has no owners destination", %{conn: conn} do
      ctxs = owners_setup(conn, [{"reader", "participant", "2026-01-01"}])

      assert {:error, {:request, :no_route}} = ask(conn, ctxs.worker, "owner")
      assert {:ok, []} = Query.all(conn, "SELECT id FROM requests")

      assert {:ok, request} = ask(conn, ctxs.worker, "either")
      assert Jason.decode!(request.arbiter) == Participant.human("test", "client")
      assert {request.route, request.destination} == {"either", "origin"}
    end

    test "a person holding both roles arbitrates both, the route tells which", %{conn: conn} do
      ctxs = owners_setup(conn, [{"both", "admin", "2026-01-01"}], "both")

      assert {:ok, owner} = ask(conn, ctxs.worker, "owner")
      assert {:ok, client} = ask(conn, ctxs.lead, nil)
      assert Jason.decode!(owner.arbiter) == Jason.decode!(client.arbiter)
      assert {owner.route, owner.destination} == {"owner", "owners"}
      assert {client.route, client.destination} == {nil, "origin"}
    end

    test "an escalation carries the route it was escalated on, and the snapshot shows it",
         %{conn: conn} do
      ctxs = owners_setup(conn, [{"boss", "admin", "2026-01-01"}])
      assert {:ok, question} = ask(conn, ctxs.worker, nil)
      assert Jason.decode!(question.arbiter) == Participant.agent("lead")

      body = %{"reason" => "Decide?", "origins" => %{"q" => question.id}, "to" => "owner"}

      assert {:ok, events} =
               Store.record_tools(
                 conn,
                 ctxs.lead.run_id,
                 [{%{name: "escalate", args: %{}}, [%{"type" => "escalate", "body" => body}]}],
                 ctxs.lead
               )

      upstream = Enum.find(events, &(&1.type == "request")).request_id
      assert {:ok, view} = Store.view(conn, "request", upstream)
      assert Jason.decode!(view.arbiter) == Participant.human("test", "boss")

      item = Omunculus.Server.Contract.item(:requests, view)
      assert {item.route, item.destination} == {"owner", "owners"}
      assert item.origins["q"].route == nil
    end

    test "only the arbiter human answers: not the client, not another owner", %{conn: conn} do
      ctxs =
        owners_setup(conn, [
          {"boss", "admin", "2026-01-01"},
          {"other", "admin", "2026-01-02"}
        ])

      assert {:ok, owner} = ask(conn, ctxs.worker, "owner")

      reply = fn subject ->
        ctx = %{
          run_id: nil,
          work_id: nil,
          author: "human",
          agent: nil,
          issuer: "test",
          subject: subject,
          config: ctxs.worker.config,
          groups: %{},
          conversation_id: ctxs.worker.conversation_id
        }

        body = %{"request_id" => owner.id, "body" => "Approved."}

        Store.record_tools(
          conn,
          nil,
          [{%{name: "reply", args: %{}}, [%{"type" => "reply", "body" => body}]}],
          ctx
        )
      end

      assert {:error, {:reply, :not_arbiter}} = reply.("client")
      assert {:error, {:reply, :not_arbiter}} = reply.("other")
      assert {:ok, [_tool, _event]} = reply.("boss")
      assert {:ok, %{status: "closed"}} = Store.view(conn, "request", owner.id)
    end

    test "a person holding both roles answers either request", %{conn: conn} do
      ctxs = owners_setup(conn, [{"both", "admin", "2026-01-01"}], "both")
      assert {:ok, owner} = ask(conn, ctxs.worker, "owner")
      assert {:ok, client} = ask(conn, ctxs.lead, nil)

      for request <- [owner, client] do
        ctx = %{
          run_id: nil,
          work_id: nil,
          author: "human",
          agent: nil,
          issuer: "test",
          subject: "both",
          config: ctxs.worker.config,
          groups: %{},
          conversation_id: ctxs.worker.conversation_id
        }

        body = %{"request_id" => request.id, "body" => "Yes."}

        assert {:ok, [_tool, _event]} =
                 Store.record_tools(
                   conn,
                   nil,
                   [{%{name: "reply", args: %{}}, [%{"type" => "reply", "body" => body}]}],
                   ctx
                 )
      end
    end

    test "a role that owns but cannot reply is refused at load" do
      dir = Path.join(System.tmp_dir!(), Id.new())
      File.mkdir_p!(dir)

      Fixtures.write_config(dir, String.replace(@owners, ~s(, "conversation.reply"]), "]"))

      assert {:error, {:access, :owner_cannot_reply, "admin"}} = Fixtures.load_config(dir)

      assert Omunculus.Errors.format({:access, :owner_cannot_reply, "admin"}) =~
               "grants project.own, so it must grant conversation.reply"
    end
  end
end
