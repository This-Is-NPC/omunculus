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
    assigned_name = pick_agent(ctx, config)
    assigned_entry = configured_agent(config, assigned_name)
    profile = Map.get(config.presets, ctx[:profile], %{})

    flow =
      if ctx[:response_contract],
        do: %{"steps" => [], "root_approval" => "self"},
        else: ctx[:flow] || Config.workflow(config, assigned_entry, profile)

    step = Enum.find(flow["steps"], &(&1["name"] == ctx[:stage])) || List.first(flow["steps"])
    name = if step, do: step["agent"] || assigned_name, else: assigned_name
    entry = configured_agent(config, name)
    kind = entry[:kind] || if(ctx.depth < ctx.max_depth, do: "concierge", else: "worker")

    tool_policy =
      if entry[:tools],
        do: elem(Omunculus.Policy.normalize(%{"mode" => "deny", "granted" => entry[:tools]}), 1)

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
    |> Map.put(:tools, if(tool_policy, do: tool_policy["granted"], else: agent.tools))
    |> Map.put(:tool_policy, tool_policy)
    |> Map.put(:kind, kind)
    |> Map.put(:response_contract, ctx[:response_contract])
    |> Map.put(:flow, flow)
    |> Map.put(:task_instructions, profile[:instructions])
    |> Map.put(
      :max_retries,
      entry[:max_retries] || profile[:max_retries] || config.defaults[:max_retries] || 2
    )
    |> Map.put(
      :system_prompt,
      Omunculus.Runtime.Prompt.compose(
        name,
        entry[:prompt],
        ctx[:response_contract]
      )
    )
  end

  def pick_agent(ctx, config) do
    agents = config.agents
    teams = config.teams || %{}
    roles = get_in(config, [:session, :roles]) || %{}
    agent = ctx[:agent]
    team = ctx[:team]

    cond do
      is_binary(agent) and agent != "" ->
        agent

      is_binary(team) and team not in ["", "default"] ->
        Map.fetch!(teams, team).lead

      true ->
        role =
          Map.get(roles, "depth#{ctx.depth}") ||
            Map.get(roles, to_string(ctx.depth))

        if is_binary(role) and role != "" do
          role
        else
          depth_fallback(ctx.depth, ctx.max_depth, agents)
        end
    end
  end

  defp depth_fallback(depth, max_depth, _agents) do
    if depth < max_depth do
      "concierge"
    else
      "worker"
    end
  end

  @default_agents Map.new(~w(concierge worker reviewer summarizer), fn name ->
                    path = Path.expand("../../../priv/agents/#{name}.md", __DIR__)
                    @external_resource path
                    {:ok, agent} = Omunculus.AgentFile.read(path)
                    {name, Omunculus.AgentFile.normalize(agent)}
                  end)

  def defaults, do: @default_agents

  defp configured_agent(config, name) do
    entry = Map.fetch!(config.agents, name)

    Omunculus.AgentFile.merge(Map.get(defaults(), name, %{}), entry)
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
