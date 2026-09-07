defmodule Omunculus.WorkflowConfigTest do
  use ExUnit.Case, async: true
  alias Omunculus.{Config, Chat.Fake}
  alias Omunculus.Runtime.{Agents, Report}

  test "config selects contextual layers, explicit kind and retry precedence" do
    dir = Path.join(System.tmp_dir!(), "workflow-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    file = Path.join(dir, "omunculus.toml")

    File.write!(file, """
    [defaults]
    max_retries = 0
    [agents.worker]
    kind = "auditor"
    prompt = "Configured agent identity"
    max_retries = 3
    [profiles.count]
    instructions = "Configured task constraints"
    max_retries = 1
    [prompts.depth]
    "0" = "Configured position"
    [prompts.kind]
    auditor = "Configured capability"
    [prompts.reason]
    retry = "Configured retry instructions"
    """)

    assert {:ok, config} = Config.load(cwd: dir, config_file: file, env: %{})
    assert {:ok, _} = Config.check(config)
    ctx = %{config: config, depth: 0, max_depth: 0, profile: "count", reason: "retry"}
    agent = Agents.resolve(ctx, %{chat: Fake.new([]) |> Map.put(:model, "test")})
    assert agent.kind == "auditor"
    assert agent.max_retries == 3
    assert config.defaults.max_retries == 0

    for text <- [
          "Configured agent identity",
          "Configured position",
          "Configured capability",
          "Configured retry instructions",
          "Configured task constraints"
        ] do
      assert agent.system_prompt =~ text
    end

    assert agent.system_prompt =~ "completed (boolean)"
    config = %{config | agents: %{}}

    agent =
      Agents.resolve(%{ctx | config: config}, %{chat: Fake.new([]) |> Map.put(:model, "test")})

    assert agent.agent_id == "worker"
    assert agent.kind == "worker"
    assert agent.max_retries == 1

    agent =
      Agents.resolve(%{ctx | config: config, profile: "coding"}, %{
        chat: Fake.new([]) |> Map.put(:model, "test")
      })

    assert agent.max_retries == 0
  end

  test "invalid retry configuration and malformed reports are rejected structurally" do
    for retries <- [-1, "2", 1.5, false] do
      config = Config.empty()

      assert {:error, {:invalid_max_retries, "defaults", ^retries}} =
               Config.check(%{config | defaults: Map.put(config.defaults, :max_retries, retries)})
    end

    for text <- [
          "done",
          ~s({"completed":"false","comment":"x"}),
          ~s({"completed":true,"comment":""}),
          ~s({"completed":true,"comment":"x","break":true}),
          ~s({"completed":false,"comment":"x","instruction":"outside comment"})
        ] do
      assert {:error, :invalid_report} = Report.parse(text)
    end

    assert {:ok, %{"completed" => false}} =
             Report.parse(~s({"completed":false,"comment":"Continue here"}))
  end

  test "optional workflows load from TOML and explicit false overrides a profile" do
    dir = Path.join(System.tmp_dir!(), "flow-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "omunculus.toml"), """
    [defaults]
    workflow = "delivery"
    root_approval = "human"
    [workflows.delivery]
    steps = [
      {name = "plan", instructions = "Plan the change"},
      {name = "review", agent = "reviewer", instructions = "Verify the effects"}
    ]
    [agents.reviewer]
    kind = "reviewer"
    model = "review-model"
    prompt = "Configured review gate"
    [profiles.coding]
    workflow = "delivery"
    [agents.worker]
    workflow = false
    root_approval = "self"
    """)

    assert {:ok, config} = Config.load(cwd: dir, env: %{})
    assert {:ok, _} = Config.check(config)

    assert Config.workflow(config, config.agents["worker"], config.presets["coding"]) == %{
             "steps" => [],
             "root_approval" => "self"
           }

    selected = Config.workflow(config, %{}, %{})
    assert Enum.map(selected["steps"], & &1["name"]) == ["plan", "review"]
    assert selected["root_approval"] == "human"

    ctx = %{
      depth: 0,
      max_depth: 0,
      reason: "step",
      stage: "review",
      flow: selected,
      config: config,
      profile: "coding"
    }

    agent = Agents.resolve(ctx, %{chat: Fake.new([]) |> Map.put(:model, "test")})
    assert agent.agent_id == "reviewer"
    assert agent.kind == "reviewer"
    assert agent.model == "review-model"
    assert agent.system_prompt =~ "Configured review gate"
    assert agent.flow == selected
    assert agent.system_prompt =~ "Verify the effects"
  end

  test "invalid workflow references and stages are rejected" do
    config = Config.empty()

    assert {:error, :invalid_workflow_config} =
             Config.check(%{config | defaults: Map.put(config.defaults, :workflow, "missing")})

    assert {:error, :invalid_workflow_config} =
             Config.check(%{
               config
               | defaults: Map.put(config.defaults, :root_approval, "concierge")
             })

    for steps <- [
          [],
          [%{"name" => "review", "instructions" => "x", "agent" => "missing"}],
          [%{"name" => "completed", "instructions" => "x"}],
          [%{"name" => "plan", "instructions" => ""}],
          [%{"name" => "plan", "instructions" => "x"}, %{"name" => "plan", "instructions" => "y"}]
        ] do
      assert {:error, :invalid_workflow_config} =
               Config.check(%{config | workflows: %{"bad" => %{"steps" => steps}}})
    end
  end
end
