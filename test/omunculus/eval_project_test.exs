Code.require_file("../../eval/lib/project.ex", __DIR__)
Code.require_file("../../eval/lib/task.ex", __DIR__)
Code.require_file("../../eval/lib/requests.ex", __DIR__)

defmodule Omunculus.EvalProjectTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Ceiling, Config, Fixtures, Harness, Id, Participant, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.RequestAccess

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
                 &Omunculus.Tools.Out.unreported/1,
                 &Omunculus.Tools.Out.request_inbox/3,
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

  defp configured_actor(conn, config, conversation, agent, work, depth, stage \\ nil) do
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
        ["promote", "sandbox.network", "request_access", "reply", "escalate", "end", "grant"]
      )

    run =
      Fixtures.open_run(conn, %{
        agent: agent,
        work_id: work,
        depth: depth,
        conversation_id: conversation,
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
