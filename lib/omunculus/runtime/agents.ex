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

    config = ctx[:config] || Config.empty()
    config = %{config | agents: Map.merge(defaults(), config.agents)}
    assigned_name = Scripts.pick_agent(ctx, config)
    assigned_entry = configured_agent(config, assigned_name, ctx)
    profile = Map.get(config.presets, ctx[:profile], %{})
    flow = ctx[:flow] || Config.workflow(config, assigned_entry, profile)
    step = Enum.find(flow["steps"], &(&1["name"] == ctx[:stage])) || List.first(flow["steps"])
    name = if step, do: step["agent"] || assigned_name, else: assigned_name
    entry = configured_agent(config, name, ctx)
    kind = entry[:kind]

    agent =
      if opts[:provider] == "chat" or is_map(opts[:chat]) do
        chat = resolve_chat(config, entry, opts)

        %{
          agent_id: name,
          kind: kind,
          model: chat.model,
          chat: chat,
          tools:
            if(ctx.depth < ctx.max_depth, do: ["delegate"], else: Omunculus.Tools.default_names()),
          max_turns:
            entry[:max_turns] || parse_turns(opts[:flags]["max_turns"]) || opts[:max_turns] ||
              config.defaults.max_turns,
          tool_options: Map.take(opts, [:delay_ms])
        }
      else
        Scripts.resolve(ctx |> Map.put(:config, config) |> Map.put(:agent, name), opts)
      end

    agent
    |> Map.put(:kind, kind)
    |> Map.put(:flow, flow)
    |> Map.put(
      :max_retries,
      entry[:max_retries] || profile[:max_retries] || config.defaults[:max_retries] || 2
    )
    |> Map.put(
      :system_prompt,
      Omunculus.Runtime.Prompt.compose(
        ctx |> Map.put(:kind, kind) |> Map.put(:flow, flow),
        name,
        entry[:prompt],
        profile[:instructions]
      )
    )
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
      "reviewer" => %{
        kind: "reviewer",
        prompt:
          "Review the existing work against the requested criteria. Report evidence, defects and the gate verdict. Do not repeat implementation effects."
      },
      "supervisor" => %{
        kind: "supervisor",
        prompt:
          "Evaluate escalated work. Recognize completed effects, direct correction or escalate."
      }
    }
  end

  defp configured_agent(config, name, ctx) do
    Map.merge(default_agent(name, ctx), Map.get(config.agents, name, %{}), fn _, default, value ->
      if is_nil(value), do: default, else: value
    end)
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
