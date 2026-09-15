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
    assert ceiling.granted == ["comment", "request_access", "work"]
    assert policy.mode == "auto"
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

  test "unknown key under policy besides layer keys and depth", %{dir: dir} do
    write_toml(dir, """
    [policy]
    workflow = "x"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:policy, {:unknown_key, "workflow"}}} = Config.load(dir)
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

  test "workspaces are parsed into layers", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    deny = ["delete"]
    human = ["deploy"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:ok, %Config{workspaces: workspaces}} = Config.load(dir)
    assert %{"app" => %Layer{deny: ["delete"], human: ["deploy"]}} = workspaces
  end

  test "invalid workspace content", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    mode = "sometimes"

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:invalid, :mode}}} = Config.load(dir)
  end

  test "unknown key inside a workspace", %{dir: dir} do
    write_toml(dir, """
    [workspaces.app]
    fs = ["read"]

    [agents.concierge]
    depth = 0
    text = "hi"
    """)

    assert {:error, {:workspace, "app", {:unknown_key, "fs"}}} = Config.load(dir)
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
    assert "comment" in agent.ceiling.granted
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
end
