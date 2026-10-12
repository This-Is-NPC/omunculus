Code.require_file("../../eval/lib/project.ex", __DIR__)

defmodule Omunculus.EvalProjectTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.{Config, Fixtures, Id, Participant, Store}
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

      conversation_id = Id.new()

      :ok =
        Query.insert(conn, :conversations, %{
          id: conversation_id,
          created_issuer: "test",
          created_subject: "owner",
          created_at: "2026-01-01"
        })

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
