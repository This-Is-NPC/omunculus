defmodule Omunculus.AgentFileTest do
  use ExUnit.Case, async: true
  alias Omunculus.{AgentFile, Config}
  alias Omunculus.Runtime.Agents

  @root Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "presets"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "imports relative to the declaring TOML, with explicit overrides and errors", %{dir: dir} do
    File.write!(
      Path.join(dir, "role.md"),
      "+++\nkind = \"worker\"\nmax_turns = 7\n+++\n# Role\nPreserve evidence.\n"
    )

    path = Path.join(dir, "presets/task.toml")
    File.write!(path, "[agents.editor]\npath = \"../role.md\"\ntools = []\nmax_turns = 9\n")
    assert {:ok, config} = Config.load(cwd: @root, config_file: path)
    assert config.agents["editor"].prompt == "# Role\nPreserve evidence."
    assert config.agents["editor"].tools == []
    assert config.agents["editor"].max_turns == 9
    assert {:ok, _} = Config.check(config)

    File.write!(path, "[agents.editor]\npath = \"../role.md\"\nprompt = \"Override\"\n")
    assert {:ok, config} = Config.load(cwd: @root, config_file: path)
    assert config.agents["editor"].prompt == "Override"
    File.rm!(Path.join(dir, "role.md"))

    assert {:error, {:invalid_agent_file, _, :enoent}} =
             Config.load(cwd: @root, config_file: path)
  end

  test "a provider overlay preserves a project-imported prompt and explicit false or empty overrides",
       %{dir: dir} do
    File.write!(
      Path.join(dir, "role.md"),
      "+++\nworkflow = \"delivery\"\n+++\nImported role"
    )

    File.write!(Path.join(dir, "omunculus.toml"), "[agents.custom]\npath = \"role.md\"\n")

    File.write!(
      Path.join(dir, "presets/provider.toml"),
      "[agents.custom]\nmodel = \"test-model\"\nworkflow = false\ntools = []\n"
    )

    assert {:ok, config} = Config.load(cwd: dir, config_file: "presets/provider.toml")
    assert config.agents["custom"].prompt == "Imported role"
    assert config.agents["custom"].model == "test-model"
    assert config.agents["custom"].workflow == false
    assert config.agents["custom"].tools == []
    assert {:ok, _} = Config.check(config)
  end

  test "rejects malformed frontmatter, unknown fields, invalid types and empty prompts" do
    for text <- [
          "No frontmatter",
          "+++\nmodel =\n+++\nRole",
          "+++\npath = \"other.md\"\n+++\nRole",
          "+++\ntools = \"read\"\n+++\nRole",
          "+++\nmax_retries = -1\n+++\nRole",
          "+++\nkind = \"worker\"\n+++\n "
        ] do
      assert {:error, _} = AgentFile.decode(text)
    end

    assert {:ok, %{"prompt" => "Role"}} = AgentFile.decode("+++\r\n+++\r\nRole")
  end

  test "tools are forbidden in agent frontmatter even when their shape is valid" do
    for value <- ["[]", "[\"read\"]"] do
      assert {:error, {:invalid_frontmatter_field, "tools"}} =
               AgentFile.decode("+++\ntools = #{value}\n+++\nRole")
    end
  end

  test "defaults come from Markdown and workflow stages resolve imported roles" do
    assert Enum.sort(Map.keys(Agents.defaults())) == ~w(concierge reviewer summarizer worker)

    for {name, entry} <- Agents.defaults() do
      assert {:ok, raw} = AgentFile.read(Path.join(@root, "priv/agents/#{name}.md"))
      assert entry == AgentFile.normalize(raw)
    end

    assert {:ok, config} =
             Config.load(cwd: @root, config_file: Path.join(@root, "examples/agents.toml"))

    assert {:ok, _} = Config.check(config)

    ctx = %{
      config: config,
      depth: 0,
      max_depth: 0,
      agent: "worker",
      stage: "review",
      profile: "coding"
    }

    agent = Agents.resolve(ctx, %{chat: %{model: "test"}})
    assert agent.agent_id == "reviewer"
    assert agent.system_prompt =~ config.agents["reviewer"].prompt
    refute "delegate" in agent.tools
    assert Enum.all?(Agents.defaults(), fn {_, entry} -> is_nil(entry.tools) end)
  end
end
