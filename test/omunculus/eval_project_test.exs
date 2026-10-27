Code.require_file("../../eval/lib/project.ex", __DIR__)
Code.require_file("../../eval/lib/task.ex", __DIR__)
Code.require_file("../../eval/lib/requests.ex", __DIR__)

defmodule Omunculus.EvalProjectTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Ceiling, Config, Fixtures, Harness, Id, Participant, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.RequestAccess

  test "an experimental overlay reuses the system steward and preserves baseline agency", %{
    conn: _conn
  } do
    overlay = Path.expand("../../eval/overlays/course-recovery.toml", __DIR__)
    overrides = Map.new(~w(sales seller administrator design-lead), &{&1, "haiku"})

    assert {:ok, path} =
             EquivalentExchange.Project.build(
               Fixtures.tmp_dir(),
               "agency",
               {"local", false},
               nil,
               overrides,
               overlay
             )

    assert {:ok, config} = Config.load(path)
    assert config.agents["steward"].depth == 0
    assert config.agents["steward"].model == "haiku"
    assert config.agents["steward"].text =~ "You are the steward of this Omunculus project"
    assert config.agents["steward"].text =~ "operational course-recovery"
    assert "correct_course" in config.agents["steward"].ceiling.granted
    catalog = config.tools |> Omunculus.Tool.Catalog.discover()
    assert catalog["escalate"].dir =~ "packs/course-recovery/tools/escalate"
    assert Map.has_key?(catalog, "skill.course-correction")
    assert {:ok, settings} = EquivalentExchange.Project.configuration("agency", overlay)
    assert settings["eval"]["entry_agent"] == "sales"
    assert {:ok, base} = EquivalentExchange.Project.configuration("agency")
    refute get_in(base, ["eval", "entry_agent"])
  end

  test "a hybrid agency overrides imported coordinators and keeps workers on the default model" do
    dir = Fixtures.tmp_dir()
    coordinators = Map.new(~w(sales seller administrator design-lead), &{&1, "haiku"})

    assert {:ok, path} =
             EquivalentExchange.Project.build(dir, "agency", {"local", true}, nil, coordinators)

    assert {:ok, config} = Config.load(path)

    for {name, agent} <- config.agents do
      assert agent.model == Map.get(coordinators, name, "local")
    end

    data = Toml.decode_file!(path)
    assert data["models"]["local"]["code_mode"]
    assert data["models"]["haiku"]["code_mode"]
  end

  test "steward recovery preserves permission origins and returns client presentation to sales",
       %{conn: conn} do
    overlay = Path.expand("../../eval/overlays/course-recovery.toml", __DIR__)

    assert {:ok, path} =
             EquivalentExchange.Project.build(
               Fixtures.tmp_dir(),
               "agency",
               {"fake", false},
               nil,
               %{},
               overlay
             )

    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)
    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

    root =
      Fixtures.insert(conn, :works, %{
        assignee: "seller",
        conversation_id: conversation,
        workflow: "sale",
        stage: "build",
        state: "waiting",
        waiting: "child"
      })

    child =
      Fixtures.insert(conn, :works, %{
        assignee: "clerk",
        parent_id: root,
        conversation_id: conversation,
        workflow: "release",
        stage: "promote"
      })

    stage = Enum.find(config.workflows["release"], &(&1.name == "promote")).ceiling
    clerk = configured_actor(conn, config, conversation, "clerk", child, 2, stage)

    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "request_access",
               %{
                 "report" => "Built",
                 "reason" => "Approve production at http://site.homologation.localhost:8080",
                 "access" => [%{"kind" => "tool", "name" => "promote"}]
               },
               clerk
             )

    origin = Enum.find(made, &(&1.type == "request")).request_id
    seller = configured_actor(conn, config, conversation, "seller", root, 0)

    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "escalate",
               %{"reason" => "Approve the built site?", "origins" => %{"production" => origin}},
               seller
             )

    envelope = Enum.find(made, &(&1.type == "request")).request_id
    sales = configured_actor(conn, config, conversation, "sales", nil, 0)

    assert {:ok, %{ok: true}, _} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => envelope, "body" => "The client has already been asked; wait."},
               sales
             )

    assert {:ok, _} = Store.close_run(conn, seller.run_id)
    assert {:ok, _} = Store.close_run(conn, sales.run_id)
    resumed = configured_actor(conn, config, conversation, "seller", root, 0, nil, envelope)
    assert {:ok, _} = Store.close_run(conn, resumed.run_id)
    assert {:ok, run} = Store.view(conn, "run", resumed.run_id)

    assert {:ok, fallback} =
             Store.unanswered(conn, run, config, &Omunculus.Tools.Out.unanswered/3)

    pending = Enum.find(fallback, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", pending)
    assert Jason.decode!(request.arbiter) == Participant.agent("steward")
    assert {:ok, []} = Store.unanswered(conn, run, config, &Omunculus.Tools.Out.unanswered/3)

    assert {:ok, []} =
             Query.all(
               conn,
               "SELECT * FROM requests WHERE json_extract(arbiter, '$.kind') = 'human'"
             )

    steward = configured_actor(conn, config, conversation, "steward", nil, 0, nil, pending)

    assert {:ok, %{ok: true}, _} =
             Harness.dispatch(project, "skill", %{"name" => "course-correction"}, steward)

    assert {:ok, %{ok: true, output: evidence}, _} =
             Harness.dispatch(project, "recovery_case", %{"request_id" => pending}, steward)

    assert evidence =~ origin
    assert evidence =~ "already been asked"
    assert Jason.decode!(evidence)["client_delivery"]["state"] == "unverified"
    assert Jason.decode!(evidence)["evidence_scope"]["recent"] =~ "not a complete history"

    assert {:ok, %{ok: false, output: refusal}, rejected} =
             Harness.dispatch(
               project,
               "correct_course",
               %{
                 "request_id" => pending,
                 "instructions" => "The client has already been asked; wait.",
                 "client_delivery" => "pending",
                 "client_request_id" => envelope,
                 "client_event_id" => request.event_id,
                 "evidence_event_ids" => [request.event_id]
               },
               steward
             )

    assert refusal =~ "Internal escalation and agent text are not proof"
    refute Enum.any?(rejected, &(&1.type in ~w(request escalate end grant)))
    assert {:ok, %{status: "pending"}} = Store.view(conn, "request", pending)

    assert {:ok, %{ok: true}, correction} =
             Harness.dispatch(
               project,
               "correct_course",
               %{
                 "request_id" => pending,
                 "client_delivery" => "unverified",
                 "evidence_event_ids" => [request.event_id],
                 "instructions" =>
                   "Inspect your Inbox and escalate the production approval to the client with its exact homologation address."
               },
               steward
             )

    assert [corrected] = Enum.filter(correction, &(&1.type == "request"))
    assert Jason.decode!(corrected.body)["arbiter"] == Participant.agent("sales")
    refute Enum.any?(correction, &(&1.type in ~w(grant prompt)))
    sales = configured_actor(conn, config, conversation, "sales", nil, 0)

    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "escalate",
               %{
                 "reason" =>
                   "Você aprova publicar as quatro páginas em http://site.homologation.localhost:8080?",
                 "origins" => %{"production" => corrected.request_id}
               },
               sales
             )

    human = Enum.find(made, &(&1.type == "request")).request_id
    assert {:ok, question} = Store.view(conn, "request", human)
    assert Jason.decode!(question.arbiter) == Participant.human("test", "owner")
    assert question.origins["production"].origins["recovery"].origins["production"].id == origin
    assert {:ok, %{grants: nil}} = Store.view(conn, "work", child)
  end

  test "model overrides reject unknown agents and model aliases" do
    for override <- [{"missing", "haiku"}, {"sales", "missing"}] do
      assert {:error, {:agent_model, ^override}} =
               EquivalentExchange.Project.build(
                 Fixtures.tmp_dir(),
                 "agency",
                 {"local", false},
                 nil,
                 Map.new([override])
               )
    end
  end

  for configuration <- EquivalentExchange.Project.configurations() do
    test "#{configuration} loads and creates decision, permission and retry requests", %{
      conn: conn
    } do
      dir = Fixtures.tmp_dir()

      assert {:ok, path} =
               EquivalentExchange.Project.build(dir, unquote(configuration), {"fake", false}, nil)

      assert {:ok, config} = Config.load(path)
      assert config.request_routes != []

      {agent, _} =
        Enum.find(config.agents, fn {_name, spec} ->
          spec.depth == 0 and not spec.workflow_only
        end)

      conversation_id = conversation(conn)

      decision = %{
        "type" => "request",
        "body" => %{
          "reason" => "Approve the scope?",
          "options" => %{"approve" => [], "deny" => []}
        }
      }

      permission = fn work_id ->
        RequestAccess.run(%{
          work_id: work_id,
          args: %{
            "report" => "Blocked",
            "reason" => "Need network",
            "access" => [%{"kind" => "resource", "name" => "sandbox.network"}]
          },
          view: %{"grant_scopes" => []}
        })["emit"]
      end

      forms =
        [fn _ -> [decision] end, permission] ++
          if(config.agents["seller"],
            do: [fn _ -> [put_in(decision, ["body", "to"], "owner")] end],
            else: []
          )

      for form <- forms do
        {run, ctx} = opening(conn, config, agent, conversation_id)
        emits = form.(ctx.work_id)

        assert {:ok, events} =
                 Store.record_tools(conn, run.id, [{%{name: "request", args: %{}}, emits}], ctx)

        event = Enum.find(events, &(&1.type == "request"))
        assert {:ok, request} = Store.view(conn, "request", event.request_id)
        assert request.status == "pending"
        assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")
      end

      {run, _ctx} = opening(conn, config, agent, conversation_id)
      assert {:ok, _} = Store.close_run(conn, run.id)

      assert {:ok, {:stopped, events}} =
               Store.unreported(
                 conn,
                 run,
                 0,
                 &Omunculus.Tools.Out.unreported/3,
                 &Omunculus.Tools.Out.request_inbox/2,
                 config
               )

      assert Enum.any?(events, &(&1.type == "request"))
    end
  end

  for option <- ~w(grant deny) do
    test "dream-team promote reaches its human for #{option}, refusing any administrator answer",
         %{conn: conn} do
      dir = Fixtures.tmp_dir()

      assert {:ok, path} =
               EquivalentExchange.Project.build(dir, "dream-team", {"fake", false}, nil)

      assert {:ok, config} = Config.load(path)

      conversation = conversation(conn)

      root =
        Fixtures.insert(conn, :works, %{
          assignee: "administrator",
          conversation_id: conversation,
          state: "waiting",
          waiting: "child"
        })

      child =
        Fixtures.insert(conn, :works, %{
          assignee: "clerk",
          parent_id: root,
          conversation_id: conversation,
          workflow: "release",
          stage: "promote"
        })

      project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

      clerk =
        configured_actor(
          conn,
          config,
          conversation,
          "clerk",
          child,
          1,
          Enum.find(config.workflows["release"], &(&1.name == "promote")).ceiling
        )

      admin = configured_actor(conn, config, conversation, "administrator", root, 0)

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "request_access",
                 %{
                   "report" => "Preview is ready",
                   "reason" => "Approve production",
                   "access" => [%{"kind" => "tool", "name" => "promote"}]
                 },
                 clerk
               )

      origin = Enum.find(events, &(&1.type == "request")).request_id
      assert {:ok, request} = Store.view(conn, "request", origin)
      assert Jason.decode!(request.arbiter) == Participant.agent("administrator")

      for answer <- [%{"option" => "grant"}, %{"option" => "deny"}, %{}] do
        assert {:ok, %{ok: false}, _} =
                 Harness.dispatch(
                   project,
                   "reply",
                   Map.merge(%{"request_id" => origin, "body" => "My decision"}, answer),
                   admin
                 )

        assert {:ok, %{status: "pending"}} = Store.view(conn, "request", origin)
        assert {:ok, %{state: "waiting", grants: nil}} = Store.view(conn, "work", child)
      end

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "escalate",
                 %{
                   "reason" => "Only the human decides production",
                   "origins" => %{"production" => origin}
                 },
                 admin
               )

      upstream = Enum.find(events, &(&1.type == "request")).request_id
      assert {:ok, request} = Store.view(conn, "request", upstream)
      assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")

      human = human(config, conversation)

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "reply",
                 %{
                   "request_id" => upstream,
                   "body" => "Human decision",
                   "parts" => %{
                     "production" => %{"body" => "Human decision", "option" => unquote(option)}
                   }
                 },
                 human
               )

      assert {:ok, %{status: "closed", answer: chosen}} = Store.view(conn, "request", origin)
      assert chosen == unquote(option)
      grants = Enum.filter(events, &(&1.type == "grant"))

      if unquote(option) == "grant" do
        assert [grant] = grants
        assert grant.work_id == child and grant.actor_kind == "human"
        assert {:ok, %{grants: "[\"promote\"]"}} = Store.view(conn, "work", child)
      else
        assert grants == []
        assert {:ok, %{grants: nil}} = Store.view(conn, "work", child)
      end

      assert {:ok, %{grants: nil, waiting: "child"}} = Store.view(conn, "work", root)
    end
  end

  test "human-gated worker network request escalates through Father and the eval responder grants its origin",
       %{conn: conn} do
    dir = Fixtures.tmp_dir()

    assert {:ok, path} =
             EquivalentExchange.Project.build(dir, "human-gated", {"fake", false}, nil)

    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)

    root =
      Fixtures.insert(conn, :works, %{
        assignee: "father",
        conversation_id: conversation,
        state: "waiting",
        waiting: "child"
      })

    child =
      Fixtures.insert(conn, :works, %{
        assignee: "edward",
        parent_id: root,
        conversation_id: conversation
      })

    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}
    worker = configured_actor(conn, config, conversation, "edward", child, 1)
    father = configured_actor(conn, config, conversation, "father", root, 0)

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "request_access",
               %{
                 "report" => "Need a dependency",
                 "reason" => "Download dependency",
                 "access" => [%{"kind" => "resource", "name" => "sandbox.network"}]
               },
               worker
             )

    origin = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", origin)
    assert Jason.decode!(request.arbiter) == Participant.agent("father")

    assert {:ok, %{ok: false}, _} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => origin, "body" => "Denied", "option" => "deny"},
               father
             )

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "escalate",
               %{
                 "reason" => "Network needs a human decision",
                 "origins" => %{"network" => origin}
               },
               father
             )

    upstream = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", upstream)
    assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")

    answer =
      EquivalentExchange.Requests.choose(
        %{human: %{"sandbox.network" => "grant"}},
        %{},
        request,
        config.root
      )

    assert answer["parts"]["network"]["option"] == "grant"
    arguments = EquivalentExchange.Requests.arguments(path, upstream, answer)
    assert ["--parts", encoded] = Enum.take(arguments, -2)
    human = human(config, conversation)

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => upstream, "body" => answer["body"], "parts" => encoded},
               human
             )

    assert [%{work_id: ^child, actor_kind: "human"}] = Enum.filter(events, &(&1.type == "grant"))
    assert {:ok, %{status: "closed", answer: "grant"}} = Store.view(conn, "request", origin)

    assert {:ok, %{state: "open", grants: "[\"sandbox.network\"]"}} =
             Store.view(conn, "work", child)

    assert {:ok, %{grants: nil, waiting: "child"}} = Store.view(conn, "work", root)
  end

  for configuration <- ~w(dream-team sales-desk agency) do
    test "#{configuration} release's promote stage ends only through promote or break" do
      dir = Fixtures.tmp_dir()

      assert {:ok, path} =
               EquivalentExchange.Project.build(dir, unquote(configuration), {"fake", false}, nil)

      assert {:ok, config} = Config.load(path)
      catalog = Omunculus.Tool.Catalog.discover(config.tools)
      assert %{chains: ["comment", "continue", "end"], then: ["end"]} = catalog["promote"]
      stage = Enum.find(config.workflows["release"], &(&1.name == "promote")).ceiling

      ceiling =
        Ceiling.mount(
          config,
          %{
            agent: "clerk",
            depth: config.agents["clerk"].depth,
            grants: ["promote"],
            stage: stage,
            workspace: Config.workspace_ceiling(config, nil),
            groups: Omunculus.Tool.Catalog.groups(catalog)
          },
          Map.keys(catalog)
        )

      assert Ceiling.classify(ceiling, "done", "tool") == "blocked"

      for name <- ["promote", "break" | catalog["promote"].chains],
          do: assert(Ceiling.classify(ceiling, name, "tool") == "have")
    end
  end

  for option <- ~w(grant deny) do
    test "agency promote follows the task human #{option} through nested escalation", %{
      conn: conn
    } do
      dir = Fixtures.tmp_dir()
      assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
      assert {:ok, config} = Config.load(path)
      conversation = conversation(conn)
      project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

      seller_work =
        Fixtures.insert(conn, :works, %{
          assignee: "seller",
          conversation_id: conversation,
          workflow: "sale",
          stage: "build",
          state: "waiting",
          waiting: "child"
        })

      admin_work =
        Fixtures.insert(conn, :works, %{
          assignee: "administrator",
          parent_id: seller_work,
          conversation_id: conversation,
          state: "waiting",
          waiting: "child"
        })

      release =
        Fixtures.insert(conn, :works, %{
          assignee: "clerk",
          parent_id: admin_work,
          conversation_id: conversation,
          workflow: "release",
          stage: "promote"
        })

      stage = Enum.find(config.workflows["release"], &(&1.name == "promote")).ceiling
      clerk = configured_actor(conn, config, conversation, "clerk", release, 2, stage)

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "request_access",
                 %{
                   "report" => "Preview ready",
                   "reason" => "Approve production?",
                   "access" => [%{"kind" => "tool", "name" => "promote"}]
                 },
                 clerk
               )

      origin = Enum.find(events, &(&1.type == "request")).request_id

      # The release's request is the client's approval: it goes to the
      # seller, past the administrator whose work waits on the release.
      upstream =
        Enum.reduce(
          [
            {"seller", seller_work, 0,
             Enum.find(config.workflows["sale"], &(&1.name == "build")).ceiling},
            {"sales", nil, 0, nil}
          ],
          origin,
          fn {agent, work, depth, ceiling}, id ->
            actor = configured_actor(conn, config, conversation, agent, work, depth, ceiling)
            assert {:ok, request} = Store.view(conn, "request", id)
            assert Jason.decode!(request.arbiter) == Participant.agent(agent)

            assert {:ok, %{ok: true}, events} =
                     Harness.dispatch(
                       project,
                       "escalate",
                       %{
                         "reason" => "Production approval",
                         "origins" => %{"production" => id}
                       },
                       actor
                     )

            Enum.find(events, &(&1.type == "request")).request_id
          end
        )

      assert {:ok, request} = Store.view(conn, "request", upstream)
      assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")

      task =
        Enum.find(
          EquivalentExchange.Task.all(),
          &(&1.id == "design-team/conversation/design-to-build")
        )

      task = %{task | human: Map.put(task.human, "promote", unquote(option))}

      assert {:ok, answer} =
               EquivalentExchange.Requests.answer(task, %{}, request, dir, fn _ ->
                 flunk("a permission decision must never reach the person model")
               end)

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "reply",
                 Map.put(answer, "request_id", upstream),
                 human(config, conversation)
               )

      assert {:ok, %{status: "closed", answer: chosen}} = Store.view(conn, "request", origin)
      assert chosen == unquote(option)
      grants = Enum.filter(events, &(&1.type == "grant"))

      if unquote(option) == "grant" do
        assert [%{work_id: ^release, actor_kind: "human"}] = grants
        assert {:ok, %{grants: "[\"promote\"]"}} = Store.view(conn, "work", release)
      else
        assert grants == []
        assert {:ok, %{grants: nil}} = Store.view(conn, "work", release)
      end
    end
  end

  for configuration <- ~w(sales-desk agency) do
    test "#{configuration} takes every work the generalist opens through sale", %{conn: conn} do
      dir = Fixtures.tmp_dir()

      assert {:ok, path} =
               EquivalentExchange.Project.build(dir, unquote(configuration), {"fake", false}, nil)

      assert {:ok, config} = Config.load(path)
      conversation = conversation(conn)
      project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}
      item = %{"title" => "Padaria Sol: a site", "goal" => "Quero um site."}
      sales = fn -> configured_actor(conn, config, conversation, "sales", nil, 0) end

      assert {:ok, %{ok: false, output: refusal}, _events} =
               Harness.dispatch(
                 project,
                 "work",
                 %{"report" => "Opened.", "works" => [Map.put(item, "agent", "sales")]},
                 sales.()
               )

      assert refusal =~ "works at that depth go through the workflow sale"

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "work",
                 %{"report" => "Opened.", "works" => [item]},
                 sales.()
               )

      work_id = Enum.find(events, &(&1.type == "work")).work_id

      assert {:ok, %{workflow: "sale", stage: "qualify", assignee: "seller"}} =
               Store.view(conn, "work", work_id)
    end
  end

  test "agency generalist batches received questions and distributes one client answer", %{
    conn: conn
  } do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)
    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}
    stage = Enum.find(config.workflows["sale"], &(&1.name == "qualify")).ceiling

    origins =
      for {part, question} <- [
            {"identity", "What is the business name and city?"},
            {"content", "Which menu and WhatsApp number?"}
          ],
          into: %{} do
        work =
          Fixtures.insert(conn, :works, %{
            assignee: "seller",
            conversation_id: conversation,
            workflow: "sale",
            stage: "qualify"
          })

        actor = configured_actor(conn, config, conversation, "seller", work, 0, stage)

        assert {:ok, %{ok: true}, events} =
                 Harness.dispatch(project, "ask", %{"question" => question}, actor)

        id = Enum.find(events, &(&1.type == "request")).request_id
        assert {:ok, row} = Store.view(conn, "request", id)
        assert Jason.decode!(row.arbiter) == Participant.agent("sales")
        {part, id}
      end

    sales = configured_actor(conn, config, conversation, "sales", nil, 0)
    assert {:ok, [%{requests: received}]} = Store.received_inbox(conn, sales.run_id)
    assert MapSet.new(received, & &1.id) == MapSet.new(Map.values(origins))

    for route <- ~w(client person sales) do
      assert {:ok, %{ok: false, output: output}, _} =
               Harness.dispatch(
                 project,
                 "escalate",
                 %{
                   "reason" => "Business details?",
                   "origins" => origins,
                   "to" => route
                 },
                 sales
               )

      assert output ==
               ~s(refused: "#{route}" is not a configured request route; configured route names: owner; omit to to follow the default request_routes route)
    end

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "escalate",
               %{
                 "reason" => "What are the business name, city, menu and WhatsApp number?",
                 "origins" => origins
               },
               sales
             )

    upstream = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", upstream)
    assert Jason.decode!(request.arbiter) == Participant.human("test", "owner")

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "reply",
               %{
                 "request_id" => upstream,
                 "body" => "Doce Ana, Campinas. Cake R$ 85. WhatsApp (19) 99876-5432."
               },
               human(config, conversation)
             )

    assert Enum.count(events, &(&1.type == "reply")) == 1

    for id <- Map.values(origins) do
      assert {:ok, %{status: "pending"}} = Store.view(conn, "request", id)

      assert {:ok, %{ok: true}, _} =
               Harness.dispatch(
                 project,
                 "reply",
                 %{
                   "request_id" => id,
                   "body" => "Doce Ana, Campinas. Cake R$ 85. WhatsApp (19) 99876-5432."
                 },
                 sales
               )

      assert {:ok, %{status: "closed", work_id: work}} = Store.view(conn, "request", id)
      assert {:ok, %{state: "open"}} = Store.view(conn, "work", work)
    end

    assert {:ok, []} = Store.received_inbox(conn, sales.run_id)
  end

  defp configured_actor(
         conn,
         config,
         conversation,
         agent,
         work,
         depth,
         stage \\ nil,
         request_id \\ nil
       ) do
    ceiling =
      Ceiling.mount(
        config,
        %{
          agent: agent,
          depth: depth,
          grants: [],
          stage: stage,
          workspace: Config.workspace_ceiling(config, nil),
          groups: %{}
        },
        [
          "ask",
          "work",
          "promote",
          "sandbox.network",
          "request_access",
          "reply",
          "escalate",
          "end",
          "grant",
          "correct_course",
          "recovery_case",
          "skill",
          "skill.course-correction",
          "route_ask_step",
          "route_request_access_step",
          "route_escalate_step"
        ]
      )

    run =
      Fixtures.open_run(conn, %{
        agent: agent,
        work_id: work,
        depth: depth,
        conversation_id: conversation,
        request_id: request_id,
        ceiling: ceiling
      })

    %{
      run_id: run.id,
      work_id: work,
      agent: agent,
      author: "agent",
      config: config,
      groups: %{},
      conversation_id: conversation,
      trigger: "model"
    }
  end

  defp conversation(conn) do
    id = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: id,
        created_issuer: "test",
        created_subject: "owner",
        created_at: "2026-01-01"
      })

    id
  end

  defp human(config, conversation),
    do: %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "test",
      subject: "owner",
      config: config,
      groups: %{},
      conversation_id: conversation,
      trigger: "cli"
    }

  defp opening(conn, config, agent, conversation) do
    work = Fixtures.insert(conn, :works, %{assignee: agent, conversation_id: conversation})

    run =
      Fixtures.open_run(conn, %{
        agent: agent,
        work_id: work,
        conversation_id: conversation,
        ceiling: %{
          have: ["ask", "request_access", "end"],
          askable: ["sandbox.network"],
          sealed: [],
          blocked: [],
          uncited: "blocked"
        }
      })

    {run,
     %{
       run_id: run.id,
       work_id: work,
       author: "agent",
       agent: agent,
       config: config,
       groups: %{},
       conversation_id: conversation
     }}
  end
end
