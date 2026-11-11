defmodule Omunculus.InterceptorsTest do
  use ExUnit.Case, async: true

  alias Omunculus.{ExecutionPolicyFixtures, Fixtures, Harness, Interceptors, Participant, Project}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [open_project: 1, write_tool: 4]

  @owner Participant.human("local", "owner")

  defp config(rules) do
    Fixtures.config("""
    [agents.root]
    depth = 0
    text = "root"
    [agents.worker]
    depth = 1
    text = "worker"
    [workflows.release]
    steps = [{ name = "build", agent = "root" }, { name = "promote", agent = "root" }]
    [accounts]
    owner = { kind = "human", issuer = "local", subject = "owner" }
    #{rules}
    """)
  end

  defp find(config, action, agent, facts, passed \\ []),
    do: Interceptors.find(config, action, agent, facts, passed)

  test "a rule holds the actions of its kind and agent only" do
    config =
      config("""
      [[interceptors]]
      action = "comment"
      agent = "worker"
      accounts = ["owner"]
      """)

    assert {0, %{accounts: ["owner"]}} = find(config, "comment", "worker", %{})
    assert find(config, "comment", "root", %{}) == nil
    assert find(config, "ask", "worker", %{}) == nil
  end

  test "workflow and stage narrow a rule, a tool rule names its tool" do
    config =
      config("""
      [[interceptors]]
      action = "tool"
      tool = "promote"
      workflow = "release"
      stage = "promote"
      accounts = ["owner"]
      """)

    held = %{tool: "promote", workflow: "release", stage: "promote"}
    assert {0, _rule} = find(config, "tool", "root", held)
    assert find(config, "tool", "root", %{held | stage: "build"}) == nil
    assert find(config, "tool", "root", %{held | workflow: nil, stage: nil}) == nil
    assert find(config, "tool", "root", %{held | tool: "deploy"}) == nil
  end

  test "to narrows a rule to the requester, an account or an agent" do
    config =
      config("""
      [[interceptors]]
      action = "ask"
      to = "requester"
      accounts = ["owner"]
      [[interceptors]]
      action = "ask"
      to = "worker"
      accounts = ["owner"]
      """)

    client = Participant.human("local", "client")
    assert {0, _} = find(config, "ask", "root", %{target: client, requester: client})
    assert find(config, "ask", "root", %{target: @owner, requester: client}) == nil

    assert {1, _} =
             find(config, "ask", "root", %{target: Participant.agent("worker"), requester: client})

    assert find(config, "ask", "root", %{target: nil, requester: client}) == nil
  end

  test "released rules are skipped and the first remaining one holds" do
    config =
      config("""
      [[interceptors]]
      action = "ask"
      accounts = ["owner"]
      [[interceptors]]
      action = "ask"
      accounts = ["owner"]
      """)

    assert {0, _} = find(config, "ask", "root", %{})
    assert {1, _} = find(config, "ask", "root", %{}, [0])
    assert find(config, "ask", "root", %{}, [0, 1]) == nil
  end

  describe "a tool a rule holds" do
    setup do
      dir = Fixtures.tmp_dir()
      Fixtures.install_default(dir)

      File.write!(
        Fixtures.config_path(dir),
        File.read!(Fixtures.config_path(dir)) <>
          """

          [accounts]
          owner = { kind = "human", issuer = "local", subject = "owner" }

          [[interceptors]]
          action = "tool"
          tool = "promote"
          accounts = ["owner"]
          """
      )

      %{dir: dir}
    end

    defp write_promote(dir, work_id) do
      write_tool(
        dir,
        "promote",
        """
        name = "promote"
        kind = "tool"
        triggers = ["model"]
        command = ["./run"]
        """,
        """
        #!/bin/sh
        echo '{"ok": true, "output": "promoted", "emit": [{"type": "comment", "body": {"body": "promoted", "work_id": "#{work_id}"}}]}'
        """
      )
    end

    test "is not run until the reviewer approves, then runs as its agent", %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{assignee: "concierge"})
      run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id, agent: "concierge"})
      write_promote(dir, work_id)
      policy = ExecutionPolicyFixtures.policy(dir, network: "host")

      actor = %{
        trigger: "model",
        run_id: run_id,
        author: "agent",
        agent: "concierge",
        execution: policy
      }

      assert {:ok, out, events} = Harness.dispatch(project, "promote", %{"to" => "prod"}, actor)
      assert out.output =~ "not done yet: it would run the tool promote"
      assert out.output =~ "sent to local:owner for review"
      assert ["tool", "request" | _hooks] = Enum.map(events, & &1.type)

      assert {:ok, []} =
               Query.all(project.conn, "SELECT id FROM comments WHERE body = 'promoted'")

      review = Enum.find(events, &(&1.type == "request"))
      assert %{"interception" => %{"action" => "tool"}} = Jason.decode!(review.body)

      owner = %{
        trigger: "cli",
        run_id: nil,
        author: "human",
        agent: nil,
        issuer: "local",
        subject: "owner",
        execution: policy
      }

      assert {:ok, _out, events} =
               Harness.dispatch(
                 project,
                 "reply",
                 %{"request_id" => review.request_id, "option" => "approve", "body" => "Go."},
                 owner
               )

      release = Enum.find(events, &(&1.type == "release"))
      tool = Enum.find(events, &(&1.type == "tool" and &1.released_by))
      comment = Enum.find(events, &(&1.type == "comment"))
      assert %{"tool" => "promote", "args" => %{"to" => "prod"}} = Jason.decode!(release.body)
      assert tool.released_by == review.request_id
      assert tool.actor_id == "concierge"
      assert comment.released_by == review.request_id

      # The released call is not held again by the rule that held it.
      assert {:ok, [_only]} = Query.all(project.conn, "SELECT id FROM requests")

      Project.close(project)
    end

    test "is not run when the reviewer denies it", %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{assignee: "concierge"})
      run_id = Fixtures.insert(project.conn, :runs, %{work_id: work_id, agent: "concierge"})
      write_promote(dir, work_id)
      policy = ExecutionPolicyFixtures.policy(dir, network: "host")

      assert {:ok, _out, [_tool, review | _hooks]} =
               Harness.dispatch(project, "promote", %{}, %{
                 trigger: "model",
                 run_id: run_id,
                 author: "agent",
                 agent: "concierge",
                 execution: policy
               })

      owner = %{
        trigger: "cli",
        run_id: nil,
        author: "human",
        agent: nil,
        issuer: "local",
        subject: "owner",
        execution: policy
      }

      assert {:ok, _out, events} =
               Harness.dispatch(
                 project,
                 "reply",
                 %{"request_id" => review.request_id, "option" => "deny", "body" => "Not yet."},
                 owner
               )

      assert Enum.map(events, & &1.type) == ~w(tool reply)

      assert {:ok, []} =
               Query.all(project.conn, "SELECT id FROM comments WHERE body = 'promoted'")

      Project.close(project)
    end
  end
end
