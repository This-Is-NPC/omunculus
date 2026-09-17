defmodule Omunculus.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config
  alias Omunculus.Config.Layer
  alias Omunculus.{Fixtures, Id, Project}
  alias Omunculus.Store.Query

  setup do
    dir = Path.join(System.tmp_dir!(), Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_toml(dir, contents) do
    Fixtures.write_config(dir, contents)
  end

  defp toml(dir), do: Path.join(dir, "omunculus.toml")
  defp load(dir), do: Config.load(toml(dir))
  defp grant(dir, layer, name), do: Config.grant(toml(dir), layer, name)

  defp default_preset,
    do: Application.app_dir(:omunculus, "priv/presets/default/omunculus.toml")

  defp execution_without_sandbox do
    """
    [execution]
    backend = "bubblewrap"
    runtimes = ["/usr"]
    environment = ["LANG"]
    timeout_ms = 30000
    max_output_bytes = 1048576
    max_concurrent = 4
    max_queue = 64
    queue_timeout_ms = 30000
    """
  end

  defp execution, do: execution_without_sandbox() <> "\n" <> Fixtures.sandbox_table()

  test "no project file is an error", %{dir: dir} do
    path = toml(dir)
    assert Config.load(path) == {:error, {:config, :missing, path}}
  end

  test "the default preset has worker at depth 1 and a delivery workflow with two steps" do
    assert {:ok, %Config{agents: agents, workflows: workflows} = config} =
             Config.load(default_preset())

    assert %{"worker" => %{depth: 1}} = agents
    assert %{"delivery" => [%{name: "to_do"}, %{name: "review"}]} = workflows
    assert Config.workflow_for(config, 0) == :off
  end

  test "the default preset's reviewer is workflow_only with the §9.1 ceiling" do
    assert {:ok, %Config{agents: agents}} = Config.load(default_preset())

    assert %{"reviewer" => %{depth: 1, workflow_only: true, ceiling: ceiling}} = agents
    assert ceiling.granted == ["break", "comment", "continue", "fs.read", "notify"]
  end

  test "the default delivery workflow's review step denies filesystem writes" do
    assert {:ok, %Config{workflows: workflows}} = Config.load(default_preset())

    assert %{"delivery" => [_to_do, review]} = workflows
    assert review.name == "review"
    assert review.agent == "reviewer"
    assert review.ceiling.deny == ["fs.write", "bench", "sandbox.write"]
  end

  test "execution configuration is required", %{dir: dir} do
    File.write!(Path.join(dir, "omunculus.toml"), """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:execution, :missing, keys}} = load(dir)

    assert keys == [
             "backend",
             "runtimes",
             "environment",
             "timeout_ms",
             "max_output_bytes",
             "max_concurrent",
             "max_queue",
             "queue_timeout_ms"
           ]
  end

  test "execution configuration rejects unsupported and malformed values", %{dir: dir} do
    File.write!(Path.join(dir, "omunculus.toml"), """
    [execution]
    backend = "host"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:execution, {:invalid, :backend}}} = load(dir)

    File.write!(Path.join(dir, "omunculus.toml"), """
    [execution]
    backend = "bubblewrap"
    runtimes = ["relative"]
    environment = ["BAD-NAME"]
    timeout_ms = 0
    max_output_bytes = 1
    max_concurrent = 1
    max_queue = 1
    queue_timeout_ms = 1

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:execution, {:invalid, :runtimes}}} = load(dir)
  end

  test "agent_at_depth prefers a non-workflow_only agent at the same depth on the default file" do
    {:ok, config} = Config.load(default_preset())
    assert {:ok, {"worker", %{depth: 1}}} = Config.agent_at_depth(config, 1)
  end

  test "a project file replaces the default whole", %{dir: dir} do
    write_toml(dir, """
    [agents.watcher]
    depth = 1
    text = "watch"
    """)

    assert {:ok, %Config{agents: agents}} = load(dir)
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

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.ceiling.granted == ["read", "ls"]
  end

  test "tools is an alias for granted", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["read", "ls"]
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
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

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = load(dir)
  end

  test "unknown top-level key", %{dir: dir} do
    write_toml(dir, """
    workflow = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:unknown_key, "workflow"}} = load(dir)
  end

  test "no agents at all", %{dir: dir} do
    write_toml(dir, "")

    assert {:error, :no_agents} = load(dir)
  end

  test "empty agents table is also no_agents", %{dir: dir} do
    write_toml(dir, "[agents]\n")

    assert {:error, :no_agents} = load(dir)
  end

  test "unknown key inside an agent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    fs = ["fs.read"]
    """)

    assert {:error, {:agent, "concierge", {:unknown_key, "fs"}}} = load(dir)
  end

  test "missing depth is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    text = "hi"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :depth}}} = load(dir)
  end

  test "negative depth is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = -1
    text = "hi"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :depth}}} = load(dir)
  end

  test "missing text is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    """)

    assert {:error, {:agent, "concierge", {:invalid, :text}}} = load(dir)
  end

  test "empty text is valid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = ""
    """)

    assert {:ok, %Config{agents: %{"concierge" => %{text: ""}}}} = load(dir)
  end

  test "workflow_only defaults to false", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.workflow_only == false
  end

  test "workflow_only true is parsed", %{dir: dir} do
    write_toml(dir, """
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = true
    """)

    assert {:ok, %Config{agents: %{"reviewer" => agent}}} = load(dir)
    assert agent.workflow_only == true
  end

  test "workflow_only must be a boolean", %{dir: dir} do
    write_toml(dir, """
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = "yes"
    """)

    assert {:error, {:agent, "reviewer", {:invalid, :workflow_only}}} = load(dir)
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

    {:ok, config} = load(dir)
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

    assert {:ok, %Config{workflows: workflows}} = load(dir)
    assert %{"delivery" => [_to_do, %{agent: "reviewer"}]} = workflows
  end

  test "invalid granted type", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = "read"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = load(dir)
  end

  test "granted list with a non-string entry is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = ["read", 1]
    """)

    assert {:error, {:agent, "concierge", {:invalid, :granted}}} = load(dir)
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

    assert {:ok, %Config{agents: %{"worker" => agent}}} = load(dir)

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

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.ceiling.mode == "allowlist"
  end

  test "mode alias allow maps to blocklist", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    mode = "allow"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.ceiling.mode == "blocklist"
  end

  test "invalid mode", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    mode = "sometimes"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :mode}}} = load(dir)
  end

  test "agent ceiling mode defaults to nil", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.ceiling.mode == nil
  end

  test "policy mode defaults to auto when the table is absent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{policy: policy}} = load(dir)
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

    assert {:ok, %Config{policy: policy}} = load(dir)
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

    assert {:ok, %Config{policy: policy}} = load(dir)
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

    assert {:ok, %Config{depths: depths}} = load(dir)
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

    assert {:error, {:policy, {:invalid, :depth}}} = load(dir)
  end

  test "policy depth value that is not a table is invalid", %{dir: dir} do
    write_toml(dir, """
    [policy]
    depth = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:invalid, :depth}}} = load(dir)
  end

  test "invalid layer content inside a policy depth", %{dir: dir} do
    write_toml(dir, """
    [policy.depth.2]
    mode = "sometimes"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:depth, 2, {:invalid, :mode}}}} = load(dir)
  end

  test "unknown key under policy besides layer keys, depth, and workflow", %{dir: dir} do
    write_toml(dir, """
    [policy]
    priority = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:unknown_key, "priority"}}} = load(dir)
  end

  test "invalid mode inside policy itself", %{dir: dir} do
    write_toml(dir, """
    [policy]
    mode = "sometimes"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:invalid, :mode}}} = load(dir)
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

    assert {:ok, %Config{workspaces: workspaces, policy_workspace: "app"}} = load(dir)

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

    assert {:ok, %Config{workspaces: %{"app" => %{root: root}}}} = load(dir)
    assert root == Path.join(dir, "sub/dir")
  end

  test "project root defaults to the config file directory", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{root: root}} = load(dir)
    assert root == Path.expand(dir)
  end

  test "[project] root is resolved against the config file directory", %{dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)

    write_toml(dir, """
    [project]
    root = "repo"

    [workspaces.app]
    root = "app"

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{root: project_root, workspaces: %{"app" => %{root: workspace_root}}}} =
             load(dir)

    assert project_root == root
    assert workspace_root == Path.join(root, "app")
  end

  test "an unknown [project] key is rejected", %{dir: dir} do
    write_toml(dir, """
    [project]
    name = "nope"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:project, {:unknown_key, "name"}}} = load(dir)
  end

  test "a workspace without a root is rejected", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    deny = ["delete"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:invalid, :root}}} = load(dir)
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

    assert {:error, {:workspace, "app", {:invalid, :mode}}} = load(dir)
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

    assert {:error, {:workspace, "app", {:unknown_key, "fs"}}} = load(dir)
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

    assert {:error, {:policy, {:unknown_workspace, "ghost"}}} = load(dir)
  end

  test "a workspace defined with no policy default is rejected", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    root = "app"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, :no_default_workspace}} = load(dir)
  end

  test "agent_at_depth found" do
    {:ok, config} = Config.load(default_preset())
    assert {:ok, {"concierge", %{depth: 0}}} = Config.agent_at_depth(config, 0)
  end

  test "agent_at_depth not found" do
    {:ok, config} = Config.load(default_preset())
    assert {:error, {:no_agent_at_depth, 7}} = Config.agent_at_depth(config, 7)
  end

  test "a permanent grant without a config file does not create one", %{dir: dir} do
    path = toml(dir)
    assert grant(dir, {:agent, "concierge"}, "delete") == {:error, {:config, :missing, path}}
    refute File.exists?(path)
  end

  test "grant appends to an existing tools alias list", %{dir: dir} do
    write_toml(dir, """
    [agents.worker]
    depth = 1
    tools = ["counter"]
    text = "work"
    """)

    assert :ok = grant(dir, {:agent, "worker"}, "write")

    assert File.read!(Path.join(dir, "omunculus.toml")) =~ ~s(tools = ["counter", "write"])
    assert {:ok, %Config{agents: %{"worker" => agent}}} = load(dir)
    assert agent.ceiling.granted == ["counter", "write"]
  end

  test "grant creates the depth layer when absent", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert :ok = grant(dir, {:depth, 1}, "counter")

    assert {:ok, %Config{depths: depths}} = load(dir)
    assert depths[1].granted == ["counter"]
  end

  test "duplicate grant is a no-op on the list", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    granted = ["counter"]
    """)

    assert :ok = grant(dir, {:agent, "concierge"}, "counter")

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = load(dir)
    assert agent.ceiling.granted == ["counter"]
  end

  test "grant to an unknown agent is an error", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:agent, "ghost", :unknown}} = grant(dir, {:agent, "ghost"}, "counter")
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

    assert :ok = grant(dir, {:workspace, "app"}, "write")

    assert {:ok, %Config{workspaces: workspaces}} = load(dir)
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

    assert :ok = grant(dir, {:stage, "delivery", "to_do"}, "write")

    assert {:ok, %Config{workflows: %{"delivery" => [to_do, review]}}} = load(dir)
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
             grant(dir, {:stage, "ghost", "to_do"}, "counter")
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
             grant(dir, {:stage, "delivery", "ghost"}, "counter")
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

      assert {:ok, %Config{workflows: workflows}} = load(dir)

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

      assert {:error, {:workflow, "delivery", :no_steps}} = load(dir)
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

      assert {:error, {:workflow, "delivery", :no_steps}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:invalid, :name}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:invalid, :agent}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:unknown_agent, "ghost"}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:duplicate_step, "to_do"}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:invalid, :mode}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:unknown_key, "stage"}}} = load(dir)
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

      assert {:error, {:workflow, "delivery", {:unknown_key, "note"}}} = load(dir)
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

      assert {:error, {:policy, {:unknown_workflow, "ghost"}}} = load(dir)
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

      assert {:error, {:policy, {:depth, 1, {:unknown_workflow, "ghost"}}}} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
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

      assert {:ok, config} = load(dir)
      assert {:ok, steps} = Config.workflow_for(config, 0)
      assert {:error, :off_sequence} = Config.next_step(steps, "ghost")
    end
  end

  describe "mcp" do
    test "the default preset has no MCP servers" do
      assert {:ok, %Config{mcp: []}} = Config.load(default_preset())
    end

    test "[[mcp.servers]] is parsed into name and command", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["npx", "-y", "@modelcontextprotocol/server-github"]
      protocol_version = "2025-03-26"
      """)

      assert {:ok, %Config{mcp: mcp}} = load(dir)

      assert mcp == [
               %{
                 name: "github",
                 command: ["npx", "-y", "@modelcontextprotocol/server-github"],
                 protocol_version: "2025-03-26"
               }
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
      protocol_version = "2025-03-26"

      [[mcp.servers]]
      name = "fs"
      command = ["fs-mcp"]
      protocol_version = "2024-11-05"
      """)

      assert {:ok, %Config{mcp: mcp}} = load(dir)
      assert Enum.map(mcp, & &1.name) == ["github", "fs"]
      assert Enum.map(mcp, & &1.protocol_version) == ["2025-03-26", "2024-11-05"]
    end

    test "a server missing a name is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      command = ["gh-mcp"]
      """)

      assert {:error, {:mcp, {:invalid, :name}}} = load(dir)
    end

    test "a server missing a command is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      """)

      assert {:error, {:mcp, {:invalid, :command}}} = load(dir)
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

      assert {:error, {:mcp, {:invalid, :command}}} = load(dir)
    end

    test "a server missing protocol_version is invalid", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp"]
      """)

      assert {:error, {:mcp, {:invalid, :protocol_version}}} = load(dir)
    end

    test "mcp.servers must be a list", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [mcp]
      servers = "github"
      """)

      assert {:error, {:mcp, {:invalid, :servers}}} = load(dir)
    end

    test "duplicate server names are rejected", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp"]
      protocol_version = "2025-03-26"

      [[mcp.servers]]
      name = "github"
      command = ["gh-mcp-2"]
      protocol_version = "2025-03-26"
      """)

      assert {:error, {:mcp, {:duplicate, "github"}}} = load(dir)
    end

    test "an unknown key under mcp besides servers is rejected", %{dir: dir} do
      write_toml(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"

      [mcp]
      timeout = 5
      """)

      assert {:error, {:mcp, {:unknown_key, "timeout"}}} = load(dir)
    end
  end

  describe "tools" do
    test "without [tools] paths and inline are empty", %{dir: dir} do
      write_toml(dir, """
      [tools]

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:ok, %Config{tools: %{paths: [], inline: inline}}} = load(dir)
      assert inline == %{}
    end

    test "omitting [tools] is an empty catalog, not an error", %{dir: dir} do
      File.write!(toml(dir), """
      #{execution()}
      [store]
      path = ".omunculus/store.sqlite3"

      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """)

      assert {:ok, %Config{tools: %{paths: [], inline: inline}}} = load(dir)
      assert inline == %{}
    end

    test "paths are resolved against the config file directory", %{dir: dir} do
      extra = Path.join(dir, "extra")
      File.mkdir_p!(extra)

      write_toml(dir, """
      [tools]
      paths = ["./extra"]

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:ok, %Config{tools: %{paths: [path]}}} = load(dir)
      assert path == extra
    end

    test "~ in a tools path expands to the home directory", %{dir: dir} do
      write_toml(dir, """
      [tools]
      paths = ["~/.omunculus-omunculus-test-tools"]

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:ok, %Config{tools: %{paths: [path]}}} = load(dir)
      assert path == Path.expand("~/.omunculus-omunculus-test-tools")
    end

    test "an inline tool is parsed with the section name", %{dir: dir} do
      write_toml(dir, """
      [tools.echo]
      kind = "tool"
      description = "inline echo"
      module = "Omunculus.Tools.Comment"

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:ok, %Config{tools: %{inline: %{"echo" => manifest}}}} = load(dir)
      assert manifest.name == "echo"
      assert manifest.description == "inline echo"
      assert manifest.dir == Path.expand(dir)
    end

    test "an inline tool whose name does not match the section is rejected", %{dir: dir} do
      write_toml(dir, """
      [tools.echo]
      name = "other"
      kind = "tool"
      module = "Omunculus.Tools.Comment"

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:error, {:tools, "echo", {:invalid, :name}}} = load(dir)
    end

    test "an invalid inline tool is a config error", %{dir: dir} do
      write_toml(dir, """
      [tools.echo]
      kind = "tool"

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:error, {:tools, "echo", {:invalid, :command}}} = load(dir)
    end

    test "tools.paths that is not a list is rejected", %{dir: dir} do
      write_toml(dir, """
      [tools]
      paths = "tools"

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:error, {:tools, {:invalid, :paths}}} = load(dir)
    end
  end

  describe "models" do
    test "an agent without model is an error", %{dir: dir} do
      write_toml(dir, """
      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:error, {:agent, "concierge", {:invalid, :model}}} = load(dir)
    end

    test "unknown api is an error", %{dir: dir} do
      write_toml(dir, """
      [models.local]
      api = "mystery"
      url = "http://localhost:8080/v1"

      [agents.concierge]
      depth = 0
      model = "local"
      text = "hi"
      """)

      assert {:error, {:models, "local", {:unknown_api, "mystery"}}} = load(dir)
    end

    test "missing models table is an error", %{dir: dir} do
      File.write!(toml(dir), """
      #{execution()}
      [agents.concierge]
      depth = 0
      text = "hi"
      model = "fake"
      """)

      assert {:error, {:models, :missing}} = load(dir)
    end

    test "two agents can name different models", %{dir: dir} do
      write_toml(dir, """
      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [models.battery]
      api = "module"
      module = "Omunculus.Model.Battery"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"

      [agents.worker]
      depth = 1
      model = "battery"
      text = "work"
      """)

      assert {:ok, config} = load(dir)
      assert config.agents["concierge"].model == "fake"
      assert config.agents["worker"].model == "battery"
      assert config.models["fake"].module == Omunculus.Model.Fake
      assert config.models["battery"].module == Omunculus.Model.Battery
    end

    test "openai-completions requires url, model and timeout_ms", %{dir: dir} do
      write_toml(dir, """
      [models.local]
      api = "openai-completions"
      url = "http://localhost:8080/v1"
      model = "qwen"

      [agents.concierge]
      depth = 0
      model = "local"
      text = "hi"
      """)

      assert {:error, {:models, "local", {:invalid, :timeout_ms}}} = load(dir)
    end
  end

  describe "store" do
    test "missing store table is an error", %{dir: dir} do
      File.write!(toml(dir), """
      #{execution()}
      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """)

      assert {:error, {:store, :missing}} = load(dir)
    end

    test "path is resolved against the config file", %{dir: dir} do
      write_toml(dir, """
      [store]
      path = "data/alt.sqlite3"

      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """)

      assert {:ok, config} = load(dir)
      assert config.store.path == Path.join(dir, "data/alt.sqlite3")
    end

    test "two configs in one directory can use different stores", %{dir: dir} do
      write_toml(dir, """
      [store]
      path = "one.sqlite3"

      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """)

      other = Path.join(dir, "other.toml")
      File.cp!(toml(dir), other)
      {:ok, data} = Toml.decode_file(other)
      data = put_in(data, ["store", "path"], "two.sqlite3")
      File.write!(other, Config.Toml.encode(data))

      {:ok, first} = Config.load(toml(dir))
      {:ok, second} = Config.load(other)
      {:ok, project_one} = Project.open(first)
      {:ok, project_two} = Project.open(second)

      id = Fixtures.insert(project_one.conn, :prompts, %{body: "only-in-one"})

      assert {:ok, %{body: "only-in-one"}} =
               Query.one(project_one.conn, "SELECT * FROM prompts WHERE id = ?", [id])

      assert {:ok, []} = Query.all(project_two.conn, "SELECT * FROM prompts")

      Project.close(project_one)
      Project.close(project_two)
    end
  end

  describe "sandbox" do
    defp agent do
      """
      [store]
      path = ".omunculus/store.sqlite3"

      [models.fake]
      api = "module"
      module = "Omunculus.Model.Fake"

      [agents.concierge]
      depth = 0
      model = "fake"
      text = "hi"
      """
    end

    test "missing [execution.sandbox] is an error", %{dir: dir} do
      File.write!(toml(dir), execution_without_sandbox() <> "\n" <> agent())
      assert {:error, {:execution, {:sandbox, :missing}}} = load(dir)
    end

    test "each sandbox key is required", %{dir: dir} do
      complete = %{
        "script" => "./bridge.js",
        "command" => ["deno", "run"],
        "runner" => "true",
        "exec" => ~s(exec "$@")
      }

      for key <- ~w(script command runner exec) do
        {:ok, data} = Toml.decode(execution_without_sandbox())
        data = put_in(data, ["execution", "sandbox"], Map.delete(complete, key))
        File.write!(toml(dir), Config.Toml.encode(data) <> "\n" <> agent())

        assert {:error, {:execution, {:sandbox, {:invalid, atom}}}} = load(dir)
        assert atom == String.to_existing_atom(key)
      end
    end

    test "command comes from the TOML", %{dir: dir} do
      write_toml(dir, """
      [execution.sandbox]
      script = "./bridge.js"
      command = ["deno", "run", "--allow-none"]
      runner = "true"
      exec = 'exec "$@"'

      [agents.concierge]
      depth = 0
      text = "hi"
      """)

      assert {:ok, config} = load(dir)
      assert config.execution.sandbox.command == ["deno", "run", "--allow-none"]
      assert config.execution.sandbox.script == Path.join(dir, "bridge.js")
      assert config.execution.sandbox.runner == "true"
      assert config.execution.sandbox.exec == ~s(exec "$@")
    end

    test "the default preset expands sandbox.script against the preset directory" do
      assert {:ok, config} = Config.load(default_preset())

      assert config.execution.sandbox.script ==
               Application.app_dir(:omunculus, "priv/sandbox.js")

      assert hd(config.execution.sandbox.command) == "deno"
    end
  end
end
