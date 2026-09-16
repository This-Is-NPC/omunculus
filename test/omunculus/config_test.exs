defmodule Omunculus.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config
  alias Omunculus.Config.Layer
  alias Omunculus.Id

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_toml(dir, contents) do
    File.write!(Path.join(dir, "omunculus.toml"), contents)
  end

  test "no project file yields the builtin concierge at depth 0", %{dir: dir} do
    assert {:ok, %Config{agents: agents, policy: policy}} = Config.load(dir)

    assert %{"concierge" => %{depth: 0, text: text, ceiling: ceiling}} = agents
    assert text != ""

    assert ceiling.granted == [
             "break",
             "catalog",
             "continue",
             "delegate",
             "fs.read",
             "reply",
             "store"
           ]

    assert policy.mode == "auto"
  end

  test "the default file has worker at depth 1 and a delivery workflow with two steps", %{
    dir: dir
  } do
    assert {:ok, %Config{agents: agents, workflows: workflows} = config} = Config.load(dir)

    assert %{"worker" => %{depth: 1}} = agents
    assert %{"delivery" => [%{name: "to_do"}, %{name: "review"}]} = workflows
    assert Config.workflow_for(config, 0) == :off
  end

  test "the default file's reviewer is workflow_only with the §9.1 ceiling", %{dir: dir} do
    assert {:ok, %Config{agents: agents}} = Config.load(dir)

    assert %{"reviewer" => %{depth: 1, workflow_only: true, ceiling: ceiling}} = agents
    assert ceiling.granted == ["break", "comment", "continue", "fs.read", "notify"]
  end

  test "the default delivery workflow's review step names reviewer and denies fs.write and bench",
       %{dir: dir} do
    assert {:ok, %Config{workflows: workflows}} = Config.load(dir)

    assert %{"delivery" => [_to_do, review]} = workflows
    assert review.name == "review"
    assert review.agent == "reviewer"
    assert review.ceiling.deny == ["fs.write", "bench"]
  end

  test "agent_at_depth prefers a non-workflow_only agent at the same depth on the default file",
       %{dir: dir} do
    {:ok, config} = Config.load(dir)
    assert {:ok, {"worker", %{depth: 1}}} = Config.agent_at_depth(config, 1)
  end

  test "a project file replaces the default whole", %{dir: dir} do
    write_toml(dir, """
    [agents.watcher]
    depth = 1
    text = "watch"
    """)

    assert {:ok, %Config{agents: agents}} = Config.load(dir)
    assert Map.has_key?(agents, "watcher")
    refute Map.has_key?(agents, "concierge")
  end

  test "granted list is parsed", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = ["read", "ls"]
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.granted == ["read", "ls"]
  end

  test "tools is an alias for granted", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["read", "ls"]
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.granted == ["read", "ls"]
  end

  test "both tools and granted is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["read"]
    granted = ["ls"]
    """)

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = Config.load(dir)
  end

  test "unknown top-level key", %{dir: dir} do
    write_toml(dir, """
    workflow = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:unknown_key, "workflow"}} = Config.load(dir)
  end

  test "no agents at all", %{dir: dir} do
    write_toml(dir, "")

    assert {:error, :no_agents} = Config.load(dir)
  end

  test "empty agents table is also no_agents", %{dir: dir} do
    write_toml(dir, "[agents]\n")

    assert {:error, :no_agents} = Config.load(dir)
  end

  test "unknown key inside an agent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    fs = ["fs.read"]
    """)

    assert {:error, {:agent, "concierge", {:unknown_key, "fs"}}} = Config.load(dir)
  end

  test "missing depth is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    text = "hi"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :depth}}} = Config.load(dir)
  end

  test "negative depth is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = -1
    text = "hi"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :depth}}} = Config.load(dir)
  end

  test "missing text is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    """)

    assert {:error, {:agent, "concierge", {:invalid, :text}}} = Config.load(dir)
  end

  test "empty text is valid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = ""
    """)

    assert {:ok, %Config{agents: %{"concierge" => %{text: ""}}}} = Config.load(dir)
  end

  test "workflow_only defaults to false", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.workflow_only == false
  end

  test "workflow_only true is parsed", %{dir: dir} do
    write_toml(dir, """
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = true
    """)

    assert {:ok, %Config{agents: %{"reviewer" => agent}}} = Config.load(dir)
    assert agent.workflow_only == true
  end

  test "workflow_only must be a boolean", %{dir: dir} do
    write_toml(dir, """
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = "yes"
    """)

    assert {:error, {:agent, "reviewer", {:invalid, :workflow_only}}} = Config.load(dir)
  end

  test "agent_at_depth skips a workflow_only agent at that depth when it is the only one", %{
    dir: dir
  } do
    write_toml(dir, """
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = true
    """)

    {:ok, config} = Config.load(dir)
    assert {:error, {:no_agent_at_depth, 1}} = Config.agent_at_depth(config, 1)
  end

  test "a workflow step can still name a workflow_only agent", %{dir: dir} do
    write_toml(dir, """
    [agents.worker]
    depth = 1
    text = "work"

    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = true

    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "worker" },
      { name = "review", agent = "reviewer" },
    ]
    """)

    assert {:ok, %Config{workflows: workflows}} = Config.load(dir)
    assert %{"delivery" => [_to_do, %{agent: "reviewer"}]} = workflows
  end

  test "invalid granted type", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = "read"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = Config.load(dir)
  end

  test "granted list with a non-string entry is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = ["read", 1]
    """)

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = Config.load(dir)
  end

  test "agent ceiling reads mode, negotiable, human, and deny", %{dir: dir} do
    write_toml(dir, """
    [agents.worker]
    depth = 1
    text = "work"
    mode = "allowlist"
    granted = ["counter"]
    negotiable = ["write"]
    human = ["delete"]
    deny = ["format"]
    """)

    assert {:ok, %Config{agents: %{"worker" => agent}}} = Config.load(dir)

    assert agent.ceiling == %Layer{
             mode: "allowlist",
             granted: ["counter"],
             negotiable: ["write"],
             human: ["delete"],
             deny: ["format"]
           }
  end

  test "mode alias deny maps to allowlist", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    mode = "deny"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.mode == "allowlist"
  end

  test "mode alias allow maps to blocklist", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    mode = "allow"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.mode == "blocklist"
  end

  test "invalid mode", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    mode = "sometimes"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :mode}}} = Config.load(dir)
  end

  test "agent ceiling mode defaults to nil", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.mode == nil
  end

  test "policy mode defaults to auto when the table is absent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{policy: policy}} = Config.load(dir)
    assert policy.mode == "auto"
  end

  test "policy mode defaults to auto when the key is absent", %{dir: dir} do
    write_toml(dir, """
    [policy]
    deny = ["delete"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{policy: policy}} = Config.load(dir)
    assert policy.mode == "auto"
    assert policy.deny == ["delete"]
  end

  test "policy mode can be set explicitly", %{dir: dir} do
    write_toml(dir, """
    [policy]
    mode = "blocklist"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{policy: policy}} = Config.load(dir)
    assert policy.mode == "blocklist"
  end

  test "policy depth layers are parsed by integer key", %{dir: dir} do
    write_toml(dir, """
    [policy.depth.1]
    mode = "allowlist"
    granted = ["counter"]
    negotiable = ["write"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{depths: depths}} = Config.load(dir)
    assert %{1 => %Layer{mode: "allowlist", granted: ["counter"], negotiable: ["write"]}} = depths
  end

  test "policy depth key that is not an integer is invalid", %{dir: dir} do
    write_toml(dir, """
    [policy.depth.first]
    mode = "allowlist"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:invalid, :depth}}} = Config.load(dir)
  end

  test "policy depth value that is not a table is invalid", %{dir: dir} do
    write_toml(dir, """
    [policy]
    depth = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:invalid, :depth}}} = Config.load(dir)
  end

  test "invalid layer content inside a policy depth", %{dir: dir} do
    write_toml(dir, """
    [policy.depth.2]
    mode = "sometimes"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:depth, 2, {:invalid, :mode}}}} = Config.load(dir)
  end

  test "unknown key under policy besides layer keys, depth, and workflow", %{dir: dir} do
    write_toml(dir, """
    [policy]
    priority = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:unknown_key, "priority"}}} = Config.load(dir)
  end

  test "invalid mode inside policy itself", %{dir: dir} do
    write_toml(dir, """
    [policy]
    mode = "sometimes"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:invalid, :mode}}} = Config.load(dir)
  end

  test "workspaces are parsed into a root plus a ceiling layer", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"
    deny = ["delete"]
    human = ["deploy"]

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{workspaces: workspaces, policy_workspace: "app"}} = Config.load(dir)

    assert %{"app" => %{root: root, ceiling: %Layer{deny: ["delete"], human: ["deploy"]}}} =
             workspaces

    assert root == Path.join(dir, "app")
  end

  test "a relative workspace root resolves against the project dir", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "./sub/dir"

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{workspaces: %{"app" => %{root: root}}}} = Config.load(dir)
    assert root == Path.join(dir, "sub/dir")
  end

  test "a workspace without a root is rejected", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    deny = ["delete"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:invalid, :root}}} = Config.load(dir)
  end

  test "invalid workspace content", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"
    mode = "sometimes"

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:invalid, :mode}}} = Config.load(dir)
  end

  test "unknown key inside a workspace", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"
    fs = ["read"]

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:unknown_key, "fs"}}} = Config.load(dir)
  end

  test "policy workspace names an undefined workspace", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"

    [policy]
    workspace = "ghost"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:unknown_workspace, "ghost"}}} = Config.load(dir)
  end

  test "a workspace defined with no policy default is rejected", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, :no_default_workspace}} = Config.load(dir)
  end

  test "agent_at_depth found", %{dir: dir} do
    {:ok, config} = Config.load(dir)
    assert {:ok, {"concierge", %{depth: 0}}} = Config.agent_at_depth(config, 0)
  end

  test "agent_at_depth not found", %{dir: dir} do
    {:ok, config} = Config.load(dir)
    assert {:error, {:no_agent_at_depth, 7}} = Config.agent_at_depth(config, 7)
  end

  test "grant on a project with no file creates one from the default", %{dir: dir} do
    assert :ok = Config.grant(dir, {:agent, "concierge"}, "delete")

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert "delete" in agent.ceiling.granted
    assert agent.depth == 0
    assert "store" in agent.ceiling.granted
  end

  test "grant appends to an existing tools alias list", %{dir: dir} do
    write_toml(dir, """
    [agents.worker]
    depth = 1
    tools = ["counter"]
    text = "work"
    """)

    assert :ok = Config.grant(dir, {:agent, "worker"}, "write")

    assert File.read!(Path.join(dir, "omunculus.toml")) =~ ~s(tools = ["counter", "write"])
    assert {:ok, %Config{agents: %{"worker" => agent}}} = Config.load(dir)
    assert agent.ceiling.granted == ["counter", "write"]
  end

  test "grant creates the depth layer when absent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert :ok = Config.grant(dir, {:depth, 1}, "counter")

    assert {:ok, %Config{depths: depths}} = Config.load(dir)
    assert depths[1].granted == ["counter"]
  end

  test "duplicate grant is a no-op on the list", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = ["counter"]
    """)

    assert :ok = Config.grant(dir, {:agent, "concierge"}, "counter")

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.ceiling.granted == ["counter"]
  end

  test "grant to an unknown agent is an error", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:agent, "ghost", :unknown}} = Config.grant(dir, {:agent, "ghost"}, "counter")
  end

  test "grant creates the workspace layer when absent", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert :ok = Config.grant(dir, {:workspace, "app"}, "write")

    assert {:ok, %Config{workspaces: workspaces}} = Config.load(dir)
    assert workspaces["app"].ceiling.granted == ["write"]
    assert workspaces["app"].root == Path.join(dir, "app")
  end

  test "grant to a workflow step adds to that step's granted list", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"

    [agents.worker]
    depth = 1
    text = "work"

    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "worker" },
      { name = "review", agent = "concierge" },
    ]
    """)

    assert :ok = Config.grant(dir, {:stage, "delivery", "to_do"}, "write")

    assert {:ok, %Config{workflows: %{"delivery" => [to_do, review]}}} = Config.load(dir)
    assert to_do.ceiling.granted == ["write"]
    assert review.ceiling.granted == []
  end

  test "grant to an unknown workflow is an error", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workflow, "ghost", :unknown}} =
             Config.grant(dir, {:stage, "ghost", "to_do"}, "counter")
  end

  test "grant to an unknown step is an error", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"

    [workflows.delivery]
    steps = [{ name = "to_do", agent = "concierge" }]
    """)

    assert {:error, {:workflow, "delivery", {:unknown_step, "ghost"}}} =
             Config.grant(dir, {:stage, "delivery", "ghost"}, "counter")
  end

  describe "workflows" do
    defp workers_toml do
      """
      [agents.worker]
      depth = 1
      text = "work"

      [agents.reviewer]
      depth = 1
      text = "review"
      """
    end

    test "steps parse name, agent, ceiling, and preserve order", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker", granted = ["counter"], negotiable = ["write"] },
            { name = "review", agent = "reviewer", deny = ["counter", "write"] },
          ]
          """
      )

      assert {:ok, %Config{workflows: workflows}} = Config.load(dir)

      assert %{
               "delivery" => [
                 %{name: "to_do", agent: "worker", ceiling: to_do_ceiling},
                 %{name: "review", agent: "reviewer", ceiling: review_ceiling}
               ]
             } = workflows

      assert to_do_ceiling == %Layer{granted: ["counter"], negotiable: ["write"]}
      assert review_ceiling == %Layer{deny: ["counter", "write"]}
    end

    test "missing steps is :no_steps", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          """
      )

      assert {:error, {:workflow, "delivery", :no_steps}} = Config.load(dir)
    end

    test "empty steps list is :no_steps", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = []
          """
      )

      assert {:error, {:workflow, "delivery", :no_steps}} = Config.load(dir)
    end

    test "step missing a name is invalid", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ agent = "worker" }]
          """
      )

      assert {:error, {:workflow, "delivery", {:invalid, :name}}} = Config.load(dir)
    end

    test "step missing an agent is invalid", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do" }]
          """
      )

      assert {:error, {:workflow, "delivery", {:invalid, :agent}}} = Config.load(dir)
    end

    test "step agent must be defined among agents", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "ghost" }]
          """
      )

      assert {:error, {:workflow, "delivery", {:unknown_agent, "ghost"}}} = Config.load(dir)
    end

    test "duplicate step names are rejected", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker" },
            { name = "to_do", agent = "reviewer" },
          ]
          """
      )

      assert {:error, {:workflow, "delivery", {:duplicate_step, "to_do"}}} = Config.load(dir)
    end

    test "invalid ceiling content inside a step is tagged with the workflow", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker", mode = "sometimes" }]
          """
      )

      assert {:error, {:workflow, "delivery", {:invalid, :mode}}} = Config.load(dir)
    end

    test "unknown key inside a step", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker", stage = "x" }]
          """
      )

      assert {:error, {:workflow, "delivery", {:unknown_key, "stage"}}} = Config.load(dir)
    end

    test "unknown key inside the workflow table", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker" }]
          note = "x"
          """
      )

      assert {:error, {:workflow, "delivery", {:unknown_key, "note"}}} = Config.load(dir)
    end

    test "policy workflow must be a defined workflow", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [policy]
          workflow = "ghost"
          """
      )

      assert {:error, {:policy, {:unknown_workflow, "ghost"}}} = Config.load(dir)
    end

    test "policy depth workflow must be a defined workflow", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [policy.depth.1]
          workflow = "ghost"
          """
      )

      assert {:error, {:policy, {:depth, 1, {:unknown_workflow, "ghost"}}}} = Config.load(dir)
    end

    test "policy workflow names the default workflow", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker" },
            { name = "review", agent = "reviewer" },
          ]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, [%{name: "to_do"}, %{name: "review"}]} = Config.workflow_for(config, 0)
      assert {:ok, [%{name: "to_do"}, %{name: "review"}]} = Config.workflow_for(config, 1)
    end

    test "a depth workflow overrides the policy workflow at that depth", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker" }]

          [workflows.solo]
          steps = [{ name = "only", agent = "reviewer" }]

          [policy]
          workflow = "delivery"

          [policy.depth.1]
          workflow = "solo"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, [%{name: "to_do"}]} = Config.workflow_for(config, 0)
      assert {:ok, [%{name: "only"}]} = Config.workflow_for(config, 1)
    end

    test "no policy workflow and no depth workflow is off", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker" }]
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert Config.workflow_for(config, 0) == :off
    end

    test "step_at finds a step by stage name", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker" },
            { name = "review", agent = "reviewer" },
          ]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:ok, %{name: "review", agent: "reviewer"}} = Config.step_at(steps, "review")
    end

    test "step_at returns off_sequence for an unknown stage", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker" }]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:error, :off_sequence} = Config.step_at(steps, "ghost")
    end

    test "next_step returns the following step", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker" },
            { name = "review", agent = "reviewer" },
          ]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:ok, %{name: "review"}} = Config.next_step(steps, "to_do")
    end

    test "next_step returns nil after the last step", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [
            { name = "to_do", agent = "worker" },
            { name = "review", agent = "reviewer" },
          ]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:ok, nil} = Config.next_step(steps, "review")
    end

    test "next_step returns off_sequence for an unknown stage", %{dir: dir} do
      write_toml(
        dir,
        workers_toml() <>
          """
          [workflows.delivery]
          steps = [{ name = "to_do", agent = "worker" }]

          [policy]
          workflow = "delivery"
          """
      )

      assert {:ok, config} = Config.load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:error, :off_sequence} = Config.next_step(steps, "ghost")
    end
  end

  describe "mcp" do
    test "the default file has no MCP servers", %{dir: dir} do
      assert {:ok, %Config{mcp: []}} = Config.load(dir)
    end

    test "[[mcp.servers]] is parsed into name and command", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["npx", "-y", "@modelcontextprotocol/server-github"]
      """)

      assert {:ok, %Config{mcp: mcp}} = Config.load(dir)

      assert mcp == [
               %{name: "github", command: ["npx", "-y", "@modelcontextprotocol/server-github"]}
             ]
    end

    test "several servers are parsed in order", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp"]

      [[mcp.servers]]
      name = "fs"
      command = ["fs-mcp"]
      """)

      assert {:ok, %Config{mcp: mcp}} = Config.load(dir)
      assert Enum.map(mcp, & &1.name) == ["github", "fs"]
    end

    test "a server missing a name is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      command = ["gh-mcp"]
      """)

      assert {:error, {:mcp, {:invalid, :name}}} = Config.load(dir)
    end

    test "a server missing a command is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      """)

      assert {:error, {:mcp, {:invalid, :command}}} = Config.load(dir)
    end

    test "a server with a non-list command is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = "gh-mcp"
      """)

      assert {:error, {:mcp, {:invalid, :command}}} = Config.load(dir)
    end

    test "mcp.servers must be a list", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [mcp]
      servers = "github"
      """)

      assert {:error, {:mcp, {:invalid, :servers}}} = Config.load(dir)
    end

    test "duplicate server names are rejected", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp"]

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp-2"]
      """)

      assert {:error, {:mcp, {:duplicate, "github"}}} = Config.load(dir)
    end

    test "an unknown key under mcp besides servers is rejected", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [mcp]
      timeout = 5
      """)

      assert {:error, {:mcp, {:unknown_key, "timeout"}}} = Config.load(dir)
    end
  end
end
