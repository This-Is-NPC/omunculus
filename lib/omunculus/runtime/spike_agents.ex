defmodule Omunculus.Runtime.SpikeAgents do
  @moduledoc """
  Agent configurations for the `conte até N` spike, provider-free.

  Agent is only configuration: identity/kind, chat, tools, budget. Nothing here
  says where a node sits in the tree. The runtime asks for a configuration by
  the depth of the node it is about to start: below `max_depth` it gets a
  concierge (only tool: `delegate`), at `max_depth` a worker (only tool:
  `counter`). The scripted `Chat.Fake` plays the model deterministically and
  resumes from a checkpoint when a worker is retried.
  """

  alias Omunculus.Chat.Fake

  @doc "Resolver to hand to `Omunculus.Runtime` (`agents:`)."
  def resolver(opts \\ []), do: &resolve(&1, Map.new(opts))

  def resolve(%{depth: depth, max_depth: max_depth}, %{chat: chat} = opts)
      when depth < max_depth and is_map(chat) do
    %{
      agent_id: "concierge@" <> chat.model,
      kind: "concierge",
      model: chat.model,
      tools: ["delegate"],
      max_turns: opts[:max_turns] || 6,
      chat: chat,
      system_prompt: """
      You are a concierge agent. You never do the work yourself and you never count.
      Your only tool is `delegate`. Call it exactly once, passing the user's task
      unchanged as `instruction`. When the tool result arrives, reply with only the
      number it reported and nothing else.
      """,
      nudge: fn
        %{tool_calls: 0} ->
          "You have not delegated yet. Call the delegate tool now with the user's task as instruction. Do not answer yourself."

        _ ->
          nil
      end,
      tool_options: Map.take(opts, [:delay_ms])
    }
  end

  def resolve(%{depth: depth, max_depth: max_depth} = ctx, opts) when depth < max_depth do
    reason = Map.get(ctx, :reason, "initial")
    checkpoint = Map.get(ctx, :checkpoint, %{})
    messages? = is_list(Map.get(checkpoint, "messages") || Map.get(checkpoint, :messages))

    turns =
      if reason in ["continuation", "retry"] or messages? do
        [
          fn messages -> Fake.text(delegate_result(messages)) end
        ]
      else
        [
          Fake.tool_call("delegate", %{"instruction" => ctx.instruction}, "call_delegate"),
          fn messages -> Fake.text(delegate_result(messages)) end
        ]
      end

    %{
      agent_id: "concierge@spike",
      kind: "concierge",
      model: "fake",
      tools: ["delegate"],
      max_turns: 4,
      chat: fake_chat(opts, "concierge@spike", ctx, turns),
      tool_options: Map.take(opts, [:delay_ms])
    }
  end

  def resolve(%{instruction: instruction, checkpoint: checkpoint}, %{chat: chat} = opts)
      when is_map(chat) do
    target = target(instruction, opts[:target] || 10)
    current = counter_current(checkpoint)

    %{
      agent_id: "worker@" <> chat.model,
      kind: "worker",
      model: chat.model,
      tools: ["counter"],
      max_turns: opts[:max_turns] || target - current + 4,
      chat: chat,
      system_prompt: """
      You are a counting worker. This is not a coding task and there are no files.
      Use only the counter tool: call it once per increment until it returns the
      number the user asked you to count to. Do not count in prose. After the
      target value, reply with only the final number.
      """,
      tool_options: %{
        delay_ms: opts[:delay_ms] || 0,
        tools: %{"counter" => %{increment: 1}}
      }
    }
  end

  def resolve(%{instruction: instruction, checkpoint: checkpoint} = ctx, opts) do
    target = target(instruction, opts[:target] || 10)
    current = counter_current(checkpoint)
    remaining = max(target - current, 0)

    calls =
      for n <- (current + 1)..target//1,
          do: Fake.tool_call("counter", %{}, "call_counter_#{n}")

    turns =
      calls ++
        [fn messages -> Fake.text(last_tool_result(messages, ~r/Counter value: (\d+)/)) end]

    %{
      agent_id: "worker@spike",
      kind: "worker",
      model: "fake",
      tools: ["counter"],
      max_turns: remaining + 2,
      chat: fake_chat(opts, "worker@spike", ctx, turns),
      tool_options: %{
        delay_ms: opts[:delay_ms] || 0,
        tools: %{"counter" => %{increment: 1}}
      }
    }
  end

  @doc "Parse the count target from an instruction such as `conte até 10`."
  def target(instruction, default) when is_binary(instruction) do
    case Regex.scan(~r/\d+/, instruction) do
      [] -> default
      matches -> matches |> List.last() |> hd() |> String.to_integer()
    end
  end

  defp fake_chat(opts, agent_id, ctx, default_turns) do
    case opts[:script] do
      fun when is_function(fun, 4) ->
        Fake.for_node(fun, agent_id, ctx.depth, ctx[:workspace], ctx[:team])

      _ ->
        Fake.new(default_turns)
    end
  end

  defp counter_current(checkpoint) when is_map(checkpoint) do
    get_in(checkpoint, ["counter", :value]) ||
      get_in(checkpoint, ["counter", "value"]) ||
      get_in(checkpoint, ["tool_state", "counter", :value]) ||
      get_in(checkpoint, ["tool_state", "counter", "value"]) ||
      get_in(checkpoint, [:counter, :value]) ||
      get_in(checkpoint, [:tool_state, :counter, :value]) ||
      0
  end

  defp counter_current(_), do: 0

  defp delegate_result(messages) do
    case last_tool_result(messages, ~r/Result: (.*?)\. Still pending:/) do
      "" -> last_tool_result(messages, ~r/^Result: (.+)$/)
      value -> value
    end
  end

  defp last_tool_result(messages, regex) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "tool", "content" => content} ->
        case Regex.run(regex, content) do
          [_, value] -> value
          _ -> nil
        end

      _ ->
        nil
    end)
  end
end
