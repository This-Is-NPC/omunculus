defmodule Omunculus.Chat.Scripts do
  @moduledoc "Deterministic scripts used exclusively by the fake provider and its tests."

  alias Omunculus.Chat.Fake
  alias Omunculus.Policy

  @doc "Resolver to hand to `Omunculus.Runtime` (`agents:`)."
  def resolver(opts \\ []), do: &resolve(&1, Map.new(opts))

  def resolve(ctx, opts) do
    case Map.get(ctx, :config) do
      %{agents: agents} when is_map(agents) and map_size(agents) > 0 ->
        resolve_with_config(ctx, opts, Map.get(ctx, :config))

      _ ->
        resolve_legacy(ctx, opts)
    end
  end

  defp resolve_with_config(ctx, opts, config) do
    name = pick_agent(ctx, config)
    agent_cfg = Map.get(config.agents, name, %{})
    agent_id = name
    kind = agent_kind(name, ctx)
    defaults = Map.get(config, :defaults, %{})

    max_turns =
      Map.get(agent_cfg, :max_turns) || opts[:max_turns] || Map.get(defaults, :max_turns) || 4

    if is_map(opts[:chat]) do
      %{
        agent_id: agent_id,
        kind: kind,
        model: opts[:chat].model,
        tools: tools_for(name, kind),
        max_turns: max_turns,
        chat: opts[:chat],
        system_prompt: agent_cfg.prompt || legacy_system_prompt(name, ctx, opts),
        nudge: legacy_nudge(kind),
        tool_options: Map.take(opts, [:delay_ms])
      }
    else
      %{
        agent_id: agent_id,
        kind: kind,
        model: "fake",
        tools: tools_for(name, kind),
        max_turns: max_turns_for_fake(name, ctx, opts, max_turns),
        chat: fake_chat(opts, agent_id, ctx, fake_turns(name, ctx, opts, config)),
        tool_options: tool_options_for(name, opts)
      }
    end
  end

  defp resolve_legacy(%{depth: depth, max_depth: max_depth}, %{chat: chat} = opts)
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

  defp resolve_legacy(%{depth: depth, max_depth: max_depth} = ctx, opts) when depth < max_depth do
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
          Fake.tool_call("delegate", legacy_delegate_args(ctx), "call_delegate"),
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

  defp resolve_legacy(%{instruction: instruction, checkpoint: checkpoint}, %{chat: chat} = opts)
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

  defp resolve_legacy(%{instruction: instruction, checkpoint: checkpoint} = ctx, opts) do
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

  def pick_agent(ctx, config) do
    agents = config.agents
    teams = config.teams || %{}
    roles = get_in(config, [:session, :roles]) || %{}
    agent = ctx[:agent]
    team = ctx[:team]

    cond do
      is_binary(agent) and agent != "" ->
        agent

      is_binary(team) and team != "" ->
        case Map.get(teams, team) do
          %{lead: lead} when is_binary(lead) -> lead
          _ -> depth_fallback(ctx.depth, ctx.max_depth, agents)
        end

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

  defp depth_fallback(depth, max_depth, agents) do
    if depth < max_depth do
      if Map.has_key?(agents, "concierge"), do: "concierge", else: "concierge@spike"
    else
      if Map.has_key?(agents, "worker"), do: "worker", else: "worker@spike"
    end
  end

  defp agent_kind("concierge", _ctx), do: "concierge"
  defp agent_kind("concierge@spike", _ctx), do: "concierge"

  defp agent_kind(_name, %{depth: depth, max_depth: max_depth}) when depth < max_depth,
    do: "concierge"

  defp agent_kind(_name, _ctx), do: "worker"

  defp tools_for("editor", _), do: ["write"]
  defp tools_for("concierge", _), do: ["delegate"]
  defp tools_for("concierge@spike", _), do: ["delegate"]
  defp tools_for(_, "concierge"), do: ["delegate"]
  defp tools_for(_, _), do: ["counter"]

  defp tool_options_for("editor", opts) do
    Map.take(opts, [:delay_ms])
  end

  defp tool_options_for(_name, opts) do
    %{
      delay_ms: opts[:delay_ms] || 0,
      tools: %{"counter" => %{increment: 1}}
    }
  end

  defp max_turns_for_fake("editor", _ctx, _opts, max_turns), do: max_turns
  defp max_turns_for_fake("concierge", _ctx, _opts, max_turns), do: min(max_turns, 4)
  defp max_turns_for_fake("concierge@spike", _ctx, _opts, _), do: 4

  defp max_turns_for_fake(_name, ctx, opts, _default) do
    target = target(ctx.instruction, opts[:target] || 10)
    current = counter_current(ctx.checkpoint)
    max(target - current, 0) + 2
  end

  defp fake_turns(name, ctx, opts, config) do
    cond do
      name in ["concierge", "concierge@spike"] or ctx.depth < ctx.max_depth ->
        concierge_fake_turns(ctx, config)

      name == "editor" ->
        editor_fake_turns()

      true ->
        counter_fake_turns(ctx, opts)
    end
  end

  defp concierge_fake_turns(ctx, config) do
    reason = Map.get(ctx, :reason, "initial")
    checkpoint = Map.get(ctx, :checkpoint, %{})
    messages? = is_list(Map.get(checkpoint, "messages") || Map.get(checkpoint, :messages))

    delegate_turns =
      if reason in ["continuation", "retry"] or messages? do
        [fn messages -> Fake.text(delegate_result(messages)) end]
      else
        [
          Fake.tool_call("delegate", delegate_args(ctx, config), "call_delegate"),
          fn messages -> Fake.text(delegate_result(messages)) end
        ]
      end

    if workspaces_granted?(ctx, config) do
      [Fake.tool_call("workspaces", %{}, "call_workspaces") | delegate_turns]
    else
      delegate_turns
    end
  end

  defp delegate_args(ctx, config) do
    args = %{"instruction" => ctx.instruction}
    teams = config.teams || %{}

    args =
      if map_size(teams) > 0 do
        Map.put(args, "team", infer_team(ctx.instruction, teams))
      else
        args
      end

    maybe_put_workspace(args, ctx, config)
  end

  defp legacy_delegate_args(ctx) do
    maybe_put_workspace(%{"instruction" => ctx.instruction}, ctx, %{workspaces: %{}})
  end

  defp infer_team(instruction, teams) do
    cond do
      Regex.match?(~r/conte|count|\d+/i, instruction) ->
        pick_team(teams, ~r/^count$/i) ||
          pick_team_by_lead(teams, "counter") ||
          pick_team(teams, ~r/count/i) ||
          first_team_name(teams)

      Regex.match?(~r/README|escrever|write|edit/i, instruction) ->
        pick_team(teams, ~r/^edit$/i) ||
          pick_team(teams, ~r/edit/i) ||
          first_team_name(teams)

      true ->
        first_team_name(teams)
    end
  end

  defp pick_team(teams, regex) do
    Enum.find_value(Map.keys(teams), fn name ->
      if Regex.match?(regex, name), do: name
    end)
  end

  defp pick_team_by_lead(teams, lead) do
    Enum.find_value(teams, fn {name, %{lead: l}} ->
      if l == lead, do: name
    end)
  end

  defp first_team_name(teams) do
    teams |> Map.keys() |> Enum.sort() |> List.first()
  end

  defp maybe_put_workspace(args, ctx, config) do
    case resolve_workspace(ctx, config) do
      workspace when is_binary(workspace) and workspace != "" ->
        Map.put(args, "workspace", workspace)

      _ ->
        args
    end
  end

  defp resolve_workspace(ctx, config) do
    workspaces = config.workspaces || %{}

    cond do
      is_binary(ctx[:workspace]) and ctx[:workspace] != "" ->
        ctx[:workspace]

      map_size(workspaces) > 1 ->
        infer_workspace_from_instruction(ctx.instruction, workspaces, ctx[:workspace])

      workspace_slug_in_instruction?(ctx.instruction, workspaces) ->
        workspace_slug_in_instruction(ctx.instruction, workspaces)

      true ->
        nil
    end
  end

  defp infer_workspace_from_instruction(instruction, workspaces, ctx_workspace) do
    case workspace_slug_in_instruction(instruction, workspaces) do
      nil ->
        ctx_workspace || workspaces |> Map.keys() |> Enum.sort() |> List.first()

      workspace ->
        workspace
    end
  end

  defp workspace_slug_in_instruction?(instruction, workspaces) do
    is_binary(workspace_slug_in_instruction(instruction, workspaces))
  end

  defp workspace_slug_in_instruction(instruction, workspaces) do
    instruction = String.downcase(instruction)

    Enum.find_value(Map.keys(workspaces), fn key ->
      if String.contains?(instruction, String.downcase(key)), do: key
    end)
  end

  defp workspaces_granted?(ctx, config) do
    ctx.depth == 0 and workspaces_in_bands?(ctx, config)
  end

  defp workspaces_in_bands?(ctx, config) do
    with table when is_map(table) <- Policy.table(config),
         profile <- profile_for_spike(ctx, config),
         workspace <- spike_workspace(ctx, config),
         depth <- to_string(ctx.depth || 0),
         {:ok, bands} <- Policy.line(table, profile, depth, workspace) do
      "workspaces" in (bands["granted"] || [])
    else
      _ -> false
    end
  end

  defp profile_for_spike(ctx, config) do
    ctx[:profile] || config.defaults[:preset] || config.defaults["preset"] || "coding"
  end

  defp spike_workspace(ctx, config) do
    workspaces = config.workspaces || %{}

    cond do
      is_binary(ctx[:workspace]) and ctx[:workspace] != "" -> ctx[:workspace]
      map_size(workspaces) == 1 -> workspaces |> Map.keys() |> hd()
      true -> workspaces |> Map.keys() |> Enum.sort() |> List.first() || "app"
    end
  end

  defp editor_fake_turns do
    [
      Fake.tool_call("write", %{"path" => "README.md", "content" => "# hi\n"}, "call_write"),
      Fake.text("wrote README")
    ]
  end

  defp counter_fake_turns(ctx, opts) do
    target = target(ctx.instruction, opts[:target] || 10)
    current = counter_current(ctx.checkpoint)

    calls =
      for n <- (current + 1)..target//1,
          do: Fake.tool_call("counter", %{}, "call_counter_#{n}")

    calls ++ [fn messages -> Fake.text(last_tool_result(messages, ~r/Counter value: (\d+)/)) end]
  end

  defp legacy_system_prompt("concierge", _ctx, _opts) do
    """
    You are a concierge agent. You never do the work yourself and you never count.
    Your only tool is `delegate`. Call it exactly once, passing the user's task
    unchanged as `instruction`. When the tool result arrives, reply with only the
    number it reported and nothing else.
    """
  end

  defp legacy_system_prompt(_name, _ctx, _opts) do
    """
    You are a counting worker. This is not a coding task and there are no files.
    Use only the counter tool: call it once per increment until it returns the
    number the user asked you to count to. Do not count in prose. After the
    target value, reply with only the final number.
    """
  end

  defp legacy_nudge("concierge") do
    fn
      %{tool_calls: 0} ->
        "You have not delegated yet. Call the delegate tool now with the user's task as instruction. Do not answer yourself."

      _ ->
        nil
    end
  end

  defp legacy_nudge(_), do: nil

  defp fake_chat(opts, agent_id, ctx, default_turns) do
    case opts[:script] do
      fun when is_function(fun, 5) ->
        turns =
          if Map.get(ctx, :reason) == "arbitration" and Map.get(ctx, :cross_lineage_arbitration) do
            fun.(agent_id, ctx.depth, ctx[:workspace], ctx[:team], "arbitration")
          else
            if Map.get(ctx, :reason) == "arbitration" do
              fun.(agent_id, ctx.depth, ctx[:workspace], ctx[:team], "arbitration")
            else
              fun.(
                agent_id,
                ctx.depth,
                ctx[:workspace],
                ctx[:team],
                Map.get(ctx, :reason, "initial")
              )
            end
          end

        turns =
          if Map.get(ctx, :reason) in ["continuation", "retry"] and ctx.depth == 0 and
               checkpoint_has_delegate_observation?(ctx) do
            [fn messages -> Fake.text(delegate_result(messages)) end]
          else
            turns
          end

        Fake.new(turns)

      fun when is_function(fun, 4) ->
        cond do
          Map.get(ctx, :reason) == "arbitration" and Map.get(ctx, :cross_lineage_arbitration) ->
            Fake.new([
              Fake.tool_call("forward", %{}, "call_forward"),
              Fake.text("forwarded")
            ])

          Map.get(ctx, :reason) == "arbitration" ->
            Fake.new([
              Fake.tool_call("grant", %{"reason" => "allowed"}, "call_grant"),
              Fake.text("granted")
            ])

          Map.get(ctx, :reason) in ["continuation", "retry"] and ctx.depth == 0 and
              checkpoint_has_delegate_observation?(ctx) ->
            Fake.new([fn messages -> Fake.text(delegate_result(messages)) end])

          true ->
            Fake.for_node(fun, agent_id, ctx.depth, ctx[:workspace], ctx[:team])
        end

      _ ->
        turns =
          cond do
            Map.get(ctx, :reason) == "arbitration" and Map.get(ctx, :cross_lineage_arbitration) ->
              [
                Fake.tool_call("forward", %{}, "call_forward"),
                Fake.text("forwarded")
              ]

            Map.get(ctx, :reason) == "arbitration" ->
              [
                Fake.tool_call("grant", %{"reason" => "allowed"}, "call_grant"),
                Fake.text("granted")
              ]

            true ->
              default_turns
          end

        Fake.new(turns)
    end
  end

  defp checkpoint_has_delegate_observation?(ctx) do
    checkpoint = Map.get(ctx, :checkpoint, %{})
    messages = Map.get(checkpoint, "messages") || Map.get(checkpoint, :messages) || []

    Enum.any?(messages, fn
      %{"role" => "tool", "content" => content} when is_binary(content) ->
        String.contains?(content, "Sub-agent completed")

      _ ->
        false
    end)
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
