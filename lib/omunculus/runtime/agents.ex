defmodule Omunculus.Runtime.Agents do
  @moduledoc "Resolves configured roles, teams, model and prompt for a new Run."

  alias Omunculus.{Config, Runner}
  alias Omunculus.Chat.Scripts

  def resolver(opts \\ []), do: &resolve(&1, Map.new(opts))
  def target(instruction, default), do: Scripts.target(instruction, default)

  def resolve(ctx, opts) do
    execution = ctx[:execution] || %{}

    flags =
      Map.new(Map.take(execution, [:model, :base_url, :max_turns]), fn {k, v} ->
        {Atom.to_string(k), v}
      end)

    opts =
      opts
      |> Map.merge(Map.take(execution, [:provider]))
      |> Map.update(:flags, flags, &Map.merge(&1, flags))

    if opts[:provider] == "chat" or is_map(opts[:chat]) do
      config = ctx[:config] || Config.empty()
      config = %{config | agents: Map.merge(defaults(), config.agents)}
      name = Scripts.pick_agent(ctx, config)

      entry =
        Map.merge(default_agent(name, ctx), Map.get(config.agents, name, %{}), fn _,
                                                                                  default,
                                                                                  value ->
          if is_nil(value), do: default, else: value
        end)

      kind = entry[:kind] || default_agent(name, ctx).kind
      chat = resolve_chat(config, entry, opts)
      profile = Map.get(config.presets, ctx[:profile], %{})

      %{
        agent_id: name,
        kind: kind,
        workflow: true,
        max_retries:
          entry[:max_retries] || profile[:max_retries] || config.defaults[:max_retries] || 2,
        model: chat.model,
        chat: chat,
        tools:
          if(ctx.depth < ctx.max_depth, do: ["delegate"], else: Omunculus.Tools.default_names()),
        system_prompt:
          Omunculus.Runtime.Prompt.compose(
            Map.put(ctx, :kind, kind),
            name,
            entry[:prompt],
            profile[:instructions]
          ),
        max_turns:
          entry[:max_turns] || parse_turns(opts[:flags]["max_turns"]) || opts[:max_turns] ||
            config.defaults.max_turns,
        tool_options: Map.take(opts, [:delay_ms])
      }
    else
      Scripts.resolve(ctx, opts)
    end
  end

  def defaults do
    %{
      "concierge" => %{
        kind: "concierge",
        prompt: "Route work to the appropriate workspace. Review reports and intervene on break."
      },
      "repo-concierge" => %{
        kind: "concierge",
        prompt:
          "Coordinate repository work. Delegate execution and evaluate the returned evidence."
      },
      "worker" => %{
        kind: "worker",
        prompt: "Execute the assigned work and report evidence, limitations and remaining work."
      },
      "supervisor" => %{
        kind: "supervisor",
        prompt:
          "Evaluate escalated work. Recognize completed effects, direct correction or escalate."
      }
    }
  end

  defp default_agent(name, ctx) do
    Map.get(
      defaults(),
      name,
      defaults()[if(ctx.depth < ctx.max_depth, do: "concierge", else: "worker")]
    )
  end

  defp parse_turns(nil), do: nil
  defp parse_turns(n) when is_integer(n) and n > 0, do: n

  defp parse_turns(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp resolve_chat(config, entry, %{chat: chat}) do
    %{chat | model: entry[:model] || chat.model || config.chat.model}
  end

  defp resolve_chat(config, entry, opts) do
    chat_config = Map.put(config.chat, :model, entry[:model] || config.chat.model)
    {:ok, chat} = Runner.build_chat(chat_config, opts[:flags] || %{}, opts[:env] || %{})
    chat
  end
end
