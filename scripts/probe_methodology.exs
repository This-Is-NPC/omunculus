# Offline diagnostic: mise exec -- mix run scripts/probe_methodology.exs
# Exercises the real resolver and Agent with a constant-text fake chat.
defmodule MethodologyProbe.Chat do
  def complete(_chat, messages, _tools) do
    Process.put(:probe_calls, Process.get(:probe_calls, 0) + 1)
    Process.put(:probe_messages, messages)
    {:ok, %{content: "10", tool_calls: nil, usage: nil}}
  end
end

alias Omunculus.{Agent, Config, FS}
alias Omunculus.Runtime.Agents

dir =
  Path.join(
    System.tmp_dir!(),
    "omunculus-oracle-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  )

File.mkdir_p!(dir)

{:ok, config} =
  Config.load(
    cwd: dir,
    config_file: Path.expand("../test/fixtures/config/simple.toml", __DIR__),
    env: %{}
  )

ctx = %{config: config, depth: 0, max_depth: 0, profile: "count"}
chat = %{mod: MethodologyProbe.Chat, model: "offline-probe"}
agent = Agents.resolve(ctx, %{chat: chat})
instruction = config.presets["count"].instructions

profile = %{
  configured_instructions: instruction,
  resolved_instructions: agent[:instructions],
  system_contains_profile: String.contains?(agent.system_prompt, instruction)
}

probes =
  for tools <- [["counter"], ["delegate"], ["counter", "delegate"]] do
    Process.put(:probe_calls, 0)

    Agent.run(
      instruction: "conte até 10",
      chat: chat,
      fs: FS.Memory.new(),
      tools: tools,
      max_turns: 3,
      system_prompt: agent.system_prompt,
      instructions: agent[:instructions]
    )

    msgs = Process.get(:probe_messages)

    %{
      tools: tools,
      model_calls: Process.get(:probe_calls),
      extra_user_messages: Enum.count(msgs, &(&1["role"] == "user")) - 1
    }
  end

File.mkdir_p!(Path.join(dir, "directory/README.md"))
File.mkdir_p!(Path.join(dir, "empty"))
File.write!(Path.join(dir, "empty/README.md"), "")

oracles = %{
  directory_passes_exists: File.exists?(Path.join(dir, "directory/README.md")),
  empty_file_passes_exists: File.exists?(Path.join(dir, "empty/README.md")),
  split_counters_pass_call_count: length(Enum.to_list(1..5) ++ Enum.to_list(1..5)) == 10,
  split_counters_reach_ten: 10 in (Enum.to_list(1..5) ++ Enum.to_list(1..5))
}

IO.puts(
  Jason.encode!(%{
    profile: profile,
    constant_text_probes: probes,
    synthetic_oracle_examples: oracles
  })
)
