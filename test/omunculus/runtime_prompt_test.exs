defmodule Omunculus.RuntimePromptTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Agent, Chat, Config, FS}
  alias Omunculus.Runtime.Agents

  test "configured role reaches the chat and survive continuation without duplication" do
    {:ok, config} =
      Config.load(
        cwd: System.tmp_dir!(),
        config_file: Path.expand("../fixtures/config/medium.toml", __DIR__),
        env: %{}
      )

    for depth <- [0, 1] do
      ctx = %{config: config, depth: depth, max_depth: 1, profile: "count"}
      owner = self()

      chat =
        Chat.Fake.new([
          fn messages ->
            send(owner, {:messages, messages})
            Chat.Fake.report("report")
          end
        ])
        |> Map.put(:model, "test")

      agent = Agents.resolve(ctx, %{chat: chat})

      opts = [
        instruction: "describe your task",
        chat: chat,
        fs: FS.Memory.new(),
        tools: if(depth == 0, do: ["delegate"], else: ["counter"]),
        system_prompt: agent.system_prompt
      ]

      assert {:ok, result} = Agent.run(opts)
      assert_receive {:messages, [%{"role" => "system", "content" => prompt} | _]}
      assert prompt =~ config.agents[agent.agent_id].prompt
      refute prompt =~ config.presets["count"].instructions
      refute prompt =~ "Depth:"
      refute prompt =~ "Kind:"
      refute prompt =~ "Run reason:"
      assert prompt =~ "When returning your final report"

      resumed_chat = Chat.Fake.new([Chat.Fake.report("reviewed")])
      observation = %{"role" => "tool", "content" => "Incomplete: missing evidence"}
      checkpoint = result.messages ++ [observation]

      assert {:ok, resumed} =
               Agent.run(Keyword.merge(opts, chat: resumed_chat, messages: checkpoint))

      assert Enum.take(resumed.messages, length(checkpoint)) == checkpoint
      assert Enum.count(resumed.messages, &(&1["role"] == "system")) == 1
    end
  end

  test "custom system prompt does not discard extra instructions" do
    assert {:ok, result} =
             Agent.run(
               instruction: "report",
               chat: Chat.Fake.new([Chat.Fake.report("done")]),
               fs: FS.Memory.new(),
               tools: [],
               system_prompt: "You review work.",
               instructions: "Do not alter files."
             )

    assert hd(result.messages)["content"] == "You review work.\nDo not alter files."
  end
end
