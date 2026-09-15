defmodule Omunculus.ConfigTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config
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
    assert {:ok, %Config{agents: agents}} = Config.load(dir)
    assert %{"concierge" => %{depth: 0, text: text, tools: ["comment", "work"]}} = agents
    assert text != ""
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

  test "tools list is parsed", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["read", "ls"]
    """)

    assert {:ok, %Config{agents: %{"concierge" => agent}}} = Config.load(dir)
    assert agent.tools == ["read", "ls"]
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
    ceiling = ["fs.read"]
    """)

    assert {:error, {:agent, "concierge", {:unknown_key, "ceiling"}}} = Config.load(dir)
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

  test "invalid tools type", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = "read"
    """)

    assert {:error, {:agent, "concierge", {:invalid, :tools}}} = Config.load(dir)
  end

  test "tools list with a non-string entry is invalid", %{dir: dir} do
    write_toml(dir, """
    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["read", 1]
    """)

    assert {:error, {:agent, "concierge", {:invalid, :tools}}} = Config.load(dir)
  end

  test "agent_at_depth found", %{dir: dir} do
    {:ok, config} = Config.load(dir)
    assert {:ok, {"concierge", %{depth: 0}}} = Config.agent_at_depth(config, 0)
  end

  test "agent_at_depth not found", %{dir: dir} do
    {:ok, config} = Config.load(dir)
    assert {:error, {:no_agent_at_depth, 7}} = Config.agent_at_depth(config, 7)
  end
end
