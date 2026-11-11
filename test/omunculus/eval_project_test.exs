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

    overrides =
      Map.new(~w(front-desk project-manager seller administrator design-lead), &{&1, "haiku"})

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
    assert catalog["correct_course"].dir =~ "packs/course-recovery/tools/correct_course"
    assert Map.has_key?(catalog, "skill.course-correction")
    assert {:ok, settings} = EquivalentExchange.Project.configuration("agency", overlay)
    assert settings["eval"]["entry_agent"] == "front-desk"
    assert {:ok, base} = EquivalentExchange.Project.configuration("agency")
    refute get_in(base, ["eval", "entry_agent"])
  end

  test "steward recovery preserves permission origins and returns client presentation to the front desk",
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
        assignee: "project-manager",
        conversation_id: conversation,
        workflow: "engagement",
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

    clerk =
      configured_actor(
        conn,
        config,
        conversation,
        "clerk",
        child,
        config.agents["clerk"].depth,
        stage
      )

    # The clerk's request reaches the manager, its work's parent, by the rule.
    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "request_access",
               %{
                 "report" => "Built",
                 "reason" =>
                   "The build needs the network at http://site.homologation.localhost:8080",
                 "access" => [%{"kind" => "resource", "name" => "sandbox.network"}]
               },
               clerk
             )

    origin = Enum.find(made, &(&1.type == "request")).request_id
    assert {:ok, asked} = Store.view(conn, "request", origin)
    assert Jason.decode!(asked.arbiter) == Participant.agent("project-manager")

    manager =
      configured_actor(
        conn,
        config,
        conversation,
        "project-manager",
        root,
        config.agents["project-manager"].depth
      )

    # The manager hands what it cannot settle to the steward, by name.
    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "escalate",
               %{
                 "reason" => "Approve the network for the built site?",
                 "origins" => %{"network" => origin},
                 "to" => "steward"
               },
               manager
             )

    pending = Enum.find(made, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", pending)
    assert Jason.decode!(request.arbiter) == Participant.agent("steward")

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
                 "client_request_id" => origin,
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
                   "Inspect your Inbox and escalate the network request to the client with its exact homologation address."
               },
               steward
             )

    assert [corrected] = Enum.filter(correction, &(&1.type == "request"))
    assert Jason.decode!(corrected.body)["arbiter"] == Participant.agent("front-desk")
    refute Enum.any?(correction, &(&1.type in ~w(grant prompt)))
    desk = configured_actor(conn, config, conversation, "front-desk", nil, 0)

    assert {:ok, %{ok: true}, made} =
             Harness.dispatch(
               project,
               "escalate",
               %{
                 "reason" => "Você autoriza a rede para http://site.homologation.localhost:8080?",
                 "origins" => %{"network" => corrected.request_id}
               },
               desk
             )

    human = Enum.find(made, &(&1.type == "request")).request_id
    assert {:ok, question} = Store.view(conn, "request", human)
    assert Jason.decode!(question.arbiter) == Participant.human("test", "owner")
    assert question.origins["network"].origins["recovery"].origins["network"].id == origin
    assert {:ok, %{grants: nil}} = Store.view(conn, "work", child)
  end

  test "a hybrid agency overrides imported coordinators and keeps workers on the default model" do
    dir = Fixtures.tmp_dir()

    coordinators =
      Map.new(~w(front-desk project-manager seller administrator design-lead), &{&1, "haiku"})

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

  test "model overrides reject unknown agents and model aliases" do
    for override <- [{"missing", "haiku"}, {"front-desk", "missing"}] do
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

      forms = [fn _ -> [decision] end, permission]

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

  test "dream-team builders may be granted the network by their parent, and the clerk holds promote",
       %{conn: _conn} do
    assert {:ok, path} =
             EquivalentExchange.Project.build(
               Fixtures.tmp_dir(),
               "dream-team",
               {"fake", false},
               nil
             )

    assert {:ok, config} = Config.load(path)

    class = fn agent, name, kind ->
      snapshot =
        Ceiling.mount(
          config,
          %{
            agent: agent,
            depth: config.agents[agent].depth,
            grants: [],
            stage: nil,
            workspace: nil,
            groups: %{}
          },
          ["sandbox.network", "promote"]
        )

      Ceiling.classify(snapshot, name, kind)
    end

    for agent <- ~w(administrator surgeon toolsmith tester editor language_lawyer clerk) do
      assert class.(agent, "sandbox.network", "resource") == "askable", agent
    end

    assert class.("clerk", "promote", "tool") == "have"

    for agent <- ~w(administrator surgeon) do
      assert "grant" in config.agents[agent].ceiling.granted
    end
  end

  test "dream-team promote is held for the owner, who alone answers it, and a deny stops it",
       %{conn: conn} do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "dream-team", {"fake", false}, nil)
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
    stage = Enum.find(config.workflows["release"], &(&1.name == "promote")).ceiling
    clerk = configured_actor(conn, config, conversation, "clerk", child, 1, stage)
    admin = configured_actor(conn, config, conversation, "administrator", root, 0)

    assert {:ok, %{output: held}, events} =
             Harness.dispatch(
               project,
               "promote",
               %{"homologation" => "http://site.homologation.localhost:8080: the four pages"},
               clerk
             )

    assert held =~ "not done yet"
    assert held =~ "http://site.homologation.localhost:8080"
    review = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", review)
    assert Jason.decode!(request.arbiter) == config.accounts["owner"]
    assert request.interception.action == "tool"

    for answer <- [%{"option" => "approve"}, %{"option" => "deny"}, %{}] do
      assert {:ok, %{ok: false}, _} =
               Harness.dispatch(
                 project,
                 "reply",
                 Map.merge(%{"request_id" => review, "body" => "My decision"}, answer),
                 admin
               )

      assert {:ok, %{status: "pending"}} = Store.view(conn, "request", review)
    end

    assert {:ok, %{ok: true}, _} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => review, "option" => "deny", "body" => "Not yet."},
               owner(config, conversation)
             )

    assert {:ok, %{status: "closed", answer: "deny"}} = Store.view(conn, "request", review)
    assert {:ok, %{grants: nil}} = Store.view(conn, "work", child)
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

  test "agency promote is held for the project manager, then the owner, whom the task's decision approves",
       %{conn: conn} do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)
    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

    manager_work =
      Fixtures.insert(conn, :works, %{
        assignee: "project-manager",
        conversation_id: conversation,
        workflow: "engagement",
        stage: "build",
        state: "waiting",
        waiting: "child"
      })

    admin_work =
      Fixtures.insert(conn, :works, %{
        assignee: "administrator",
        parent_id: manager_work,
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

    clerk =
      configured_actor(
        conn,
        config,
        conversation,
        "clerk",
        release,
        config.agents["clerk"].depth,
        stage
      )

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "promote",
               %{"homologation" => "http://site.homologation.localhost:8080"},
               clerk
             )

    # The manager reviews first: the client's acceptance is its to check.
    first = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", first)
    assert Jason.decode!(request.arbiter) == Participant.agent("project-manager")
    assert request.interception.step == 0

    manager =
      configured_actor(
        conn,
        config,
        conversation,
        "project-manager",
        manager_work,
        config.agents["project-manager"].depth,
        Enum.find(config.workflows["engagement"], &(&1.name == "build")).ceiling
      )

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => first, "option" => "approve", "body" => "The client accepted."},
               manager
             )

    second = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, request} = Store.view(conn, "request", second)
    assert Jason.decode!(request.arbiter) == config.accounts["owner"]
    assert request.interception.step == 1

    task =
      Enum.find(
        EquivalentExchange.Task.all(),
        &(&1.id == "design-team/conversation/design-to-build")
      )

    assert {:ok, %{"option" => "approve"}} =
             EquivalentExchange.Requests.answer(task, %{}, request, dir, fn _ ->
               flunk("a review must never reach the person model")
             end)

    assert {:ok, %{ok: true}, _} =
             Harness.dispatch(
               project,
               "reply",
               %{"request_id" => second, "option" => "deny", "body" => "Not yet."},
               owner(config, conversation)
             )

    assert {:ok, %{status: "closed", answer: "deny"}} = Store.view(conn, "request", second)
    assert {:ok, %{grants: nil}} = Store.view(conn, "work", release)
  end

  for configuration <- ~w(sales-desk agency) do
    test "#{configuration} takes every work the front desk opens through engagement", %{
      conn: conn
    } do
      dir = Fixtures.tmp_dir()

      assert {:ok, path} =
               EquivalentExchange.Project.build(dir, unquote(configuration), {"fake", false}, nil)

      assert {:ok, config} = Config.load(path)
      conversation = conversation(conn)
      project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}
      item = %{"title" => "Padaria Sol: a site", "goal" => "Quero um site."}
      sales = fn -> configured_actor(conn, config, conversation, "front-desk", nil, 0) end

      assert {:ok, %{ok: false, output: refusal}, _events} =
               Harness.dispatch(
                 project,
                 "work",
                 %{"report" => "Opened.", "works" => [Map.put(item, "agent", "front-desk")]},
                 sales.()
               )

      assert refusal =~ "works at that depth go through the workflow engagement"

      assert {:ok, %{ok: true}, events} =
               Harness.dispatch(
                 project,
                 "work",
                 %{"report" => "Opened.", "works" => [item]},
                 sales.()
               )

      work_id = Enum.find(events, &(&1.type == "work")).work_id

      assert {:ok, %{workflow: "engagement", stage: "start", assignee: "project-manager"}} =
               Store.view(conn, "work", work_id)
    end
  end

  test "agency's manager can only start the sale at stage start, which opens the seller's work",
       %{conn: conn} do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)
    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

    manager_work =
      Fixtures.insert(conn, :works, %{
        assignee: "project-manager",
        conversation_id: conversation,
        workflow: "engagement",
        stage: "start",
        title: "Padaria Sol",
        goal: "Quero um site."
      })

    stage = Enum.find(config.workflows["engagement"], &(&1.name == "start")).ceiling

    manager = fn ->
      configured_actor(
        conn,
        config,
        conversation,
        "project-manager",
        manager_work,
        config.agents["project-manager"].depth,
        stage
      )
    end

    tools = config.agents["project-manager"].ceiling.granted

    ceiling =
      Ceiling.mount(
        config,
        %{
          agent: "project-manager",
          depth: config.agents["project-manager"].depth,
          grants: [],
          stage: stage,
          workspace: Config.workspace_ceiling(config, nil),
          groups: %{}
        },
        tools
      )

    # The model is left with the sale's start, and the steps it chains.
    have = Enum.filter(tools, &(Ceiling.classify(ceiling, &1, "tool") == "have"))
    assert Enum.sort(have) == ~w(comment continue delegate end start_sale)

    assert {:ok, %{ok: true}, _} = Harness.dispatch(project, "start_sale", %{}, manager.())

    assert {:ok, %{stage: "sale", state: "waiting", waiting: "child"}} =
             Store.view(conn, "work", manager_work)

    assert {:ok, [seller]} =
             Query.all(conn, "SELECT * FROM works WHERE parent_id = ?", [manager_work])

    assert %{
             workflow: "sale",
             stage: "qualify",
             assignee: "seller",
             goal: "Quero um site.",
             title: "Padaria Sol: sale"
           } = seller
  end

  test "agency's manager hands design and build down only with the proposal's tools" do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
    assert {:ok, config} = Config.load(path)
    tools = config.agents["project-manager"].ceiling.granted

    have = fn name ->
      stage = Enum.find(config.workflows["engagement"], &(&1.name == name)).ceiling

      ceiling =
        Ceiling.mount(
          config,
          %{
            agent: "project-manager",
            depth: config.agents["project-manager"].depth,
            grants: [],
            stage: stage,
            workspace: Config.workspace_ceiling(config, nil),
            groups: %{}
          },
          tools
        )

      Enum.filter(tools, &(Ceiling.classify(ceiling, &1, "tool") == "have"))
    end

    design = have.("design")
    build = have.("build")

    assert "start_design" in design and "start_build" in build
    refute "work" in design or "work" in build
    refute "reopen" in design
    assert "reopen" in build
    assert "work" in have.("sale")
  end

  test "agency's manager hands the seller a sale and the teams their works, and the seller asks it",
       %{
         conn: conn
       } do
    dir = Fixtures.tmp_dir()
    assert {:ok, path} = EquivalentExchange.Project.build(dir, "agency", {"fake", false}, nil)
    assert {:ok, config} = Config.load(path)
    conversation = conversation(conn)
    project = %Omunculus.Project{conn: conn, dir: config.root, config_path: path}

    manager_work =
      Fixtures.insert(conn, :works, %{
        assignee: "project-manager",
        conversation_id: conversation,
        workflow: "engagement",
        stage: "sale"
      })

    stage = Enum.find(config.workflows["engagement"], &(&1.name == "sale")).ceiling

    manager =
      configured_actor(
        conn,
        config,
        conversation,
        "project-manager",
        manager_work,
        config.agents["project-manager"].depth,
        stage
      )

    works = [
      %{"title" => "Sale", "goal" => "Sell it.", "workflow" => "sale"},
      %{
        "title" => "Assess",
        "goal" => "Assessment only, build nothing: x",
        "agent" => "administrator"
      },
      %{"title" => "Preview", "goal" => "Design it.", "agent" => "design-lead"}
    ]

    assert {:ok, %{ok: true}, _} =
             Harness.dispatch(
               project,
               "work",
               %{"report" => "Handed down.", "works" => works},
               manager
             )

    assert {:ok, children} =
             Query.all(conn, "SELECT * FROM works WHERE parent_id = ? ORDER BY rowid", [
               manager_work
             ])

    [sale, assess, preview] = children

    assert %{workflow: "sale", stage: "qualify", assignee: "seller"} = sale
    assert %{assignee: "administrator"} = assess
    assert %{assignee: "design-lead"} = preview

    # The seller asks the manager, its parent, and the front desk by name.
    seller =
      configured_actor(
        conn,
        config,
        conversation,
        "seller",
        sale.id,
        config.agents["seller"].depth,
        Enum.find(config.workflows["sale"], &(&1.name == "estimate")).ceiling
      )

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "ask",
               %{"question" => "Can it be built?"},
               seller
             )

    id = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, row} = Store.view(conn, "request", id)
    assert Jason.decode!(row.arbiter) == Participant.agent("project-manager")

    assert {:ok, %{ok: true}, events} =
             Harness.dispatch(
               project,
               "ask",
               %{"question" => "Which pages?", "to" => "front-desk"},
               seller
             )

    id = Enum.find(events, &(&1.type == "request")).request_id
    assert {:ok, row} = Store.view(conn, "request", id)
    assert Jason.decode!(row.arbiter) == Participant.agent("front-desk")
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

    engagement =
      Fixtures.insert(conn, :works, %{assignee: "front-desk", conversation_id: conversation})

    origins =
      for {part, question} <- [
            {"identity", "What is the business name and city?"},
            {"content", "Which menu and WhatsApp number?"}
          ],
          into: %{} do
        work =
          Fixtures.insert(conn, :works, %{
            assignee: "seller",
            parent_id: engagement,
            conversation_id: conversation,
            workflow: "sale",
            stage: "qualify"
          })

        actor =
          configured_actor(
            conn,
            config,
            conversation,
            "seller",
            work,
            config.agents["seller"].depth,
            stage
          )

        assert {:ok, %{ok: true}, events} =
                 Harness.dispatch(project, "ask", %{"question" => question}, actor)

        id = Enum.find(events, &(&1.type == "request")).request_id
        assert {:ok, row} = Store.view(conn, "request", id)
        assert Jason.decode!(row.arbiter) == Participant.agent("front-desk")
        {part, id}
      end

    sales = configured_actor(conn, config, conversation, "front-desk", nil, 0)
    assert {:ok, [%{requests: received}]} = Store.received_inbox(conn, sales.run_id)
    assert MapSet.new(received, & &1.id) == MapSet.new(Map.values(origins))

    for {to, refusal} <- [
          {"client", "neither an account nor an agent"},
          {"person", "neither an account nor an agent"},
          {"front-desk", "is you"}
        ] do
      assert {:ok, %{ok: false, output: output}, _} =
               Harness.dispatch(
                 project,
                 "escalate",
                 %{
                   "reason" => "Business details?",
                   "origins" => origins,
                   "to" => to
                 },
                 sales
               )

      assert output =~ ~s(refused: "#{to}" ) and output =~ refusal
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
          "comment",
          "continue",
          "delegate",
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
          "skill.course-correction"
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

  # The account `owner` the eval configurations declare, as the person.
  defp owner(config, conversation),
    do:
      conversation
      |> then(&human(config, &1))
      |> Map.merge(%{
        issuer: config.accounts["owner"]["issuer"],
        subject: config.accounts["owner"]["subject"]
      })

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
