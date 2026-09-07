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
end
