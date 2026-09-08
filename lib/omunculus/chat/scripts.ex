defmodule Omunculus.Chat.Scripts do
  @moduledoc "Deterministic scripts used exclusively by the fake provider and its tests."

  alias Omunculus.Chat.Fake
  alias Omunculus.Policy

  @doc "Resolver to hand to `Omunculus.Runtime` (`agents:`)."
  def resolver(opts \\ []), do: &resolve(&1, Map.new(opts))

  def resolve(ctx, opts) do
    config = ctx[:config] || Omunculus.Config.empty()
    config = %{config | agents: Map.merge(Omunculus.Runtime.Agents.defaults(), config.agents)}
    name = Omunculus.Runtime.Agents.pick_agent(ctx, config)
    entry = config.agents[name] || %{}
    kind = entry[:kind] || if(ctx.depth < ctx.max_depth, do: "concierge", else: "worker")

    %{
      agent_id: name,
      kind: kind,
      model: "fake",
      tools: tools_for(name, kind),
      max_turns: max_turns_for_fake(name, ctx, opts, entry[:max_turns] || opts[:max_turns] || 4),
      chat: fake_chat(opts, name, ctx, fake_turns(name, ctx, opts, config)),
      tool_options: tool_options_for(name, opts)
    }
  end

  @doc "Parse the count target from an instruction such as `conte até 10`."
  def target(instruction, default) when is_binary(instruction) do
    case Regex.scan(~r/\d+/, instruction) do
      [] -> default
      matches -> matches |> List.last() |> hd() |> String.to_integer()
    end
  end

  defp tools_for("editor", _), do: ["write"]
  defp tools_for("concierge", _), do: ["delegate"]
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

  defp max_turns_for_fake(_name, ctx, opts, _default) do
    target = target(ctx.instruction, opts[:target] || 10)
    current = counter_current(ctx.checkpoint)
    max(target - current, 0) + 2
  end

  defp fake_turns(name, ctx, opts, config) do
    cond do
      name == "concierge" or ctx.depth < ctx.max_depth ->
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
        [fn messages -> Fake.report(delegate_result(messages)) end]
      else
        [
          Fake.tool_call("delegate", delegate_args(ctx, config), "call_delegate"),
          fn messages -> Fake.report(delegate_result(messages)) end
        ]
      end

    if workspaces_granted?(ctx, config) do
      [Fake.tool_call("workspaces", %{}, "call_workspaces") | delegate_turns]
    else
      delegate_turns
    end
  end

  defp delegate_args(ctx, config) do
    args = %{"instruction" => ctx.instruction, "comment" => "Delegated task: " <> ctx.instruction}
    teams = config.teams || %{}

    args =
      if map_size(teams) > 0 do
        Map.put(args, "team", infer_team(ctx.instruction, teams))
      else
        args
      end

    maybe_put_workspace(args, ctx, config)
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
      Fake.report("wrote README")
    ]
  end

  defp counter_fake_turns(ctx, opts) do
    target = target(ctx.instruction, opts[:target] || 10)
    current = counter_current(ctx.checkpoint)

    calls =
      for n <- (current + 1)..target//1,
          do: Fake.tool_call("counter", %{}, "call_counter_#{n}")

    calls ++
      [fn messages -> Fake.report(last_tool_result(messages, ~r/Counter value: (\d+)/)) end]
  end

  defp fake_chat(opts, agent_id, ctx, default_turns) do
    case opts[:script] do
      _ when ctx.reason == "break" ->
        Fake.new([
          Fake.text(
            Jason.encode!(%{
              completed: false,
              break: true,
              comment: "Technical failure needs operator review"
            })
          )
        ])

      _ when ctx.reason == "assessment" ->
        Fake.new([Fake.report(ctx.assessment["comment"] || "Reviewed existing work")])

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
            [fn messages -> Fake.report(delegate_result(messages)) end]
          else
            turns
          end

        Fake.new(turns)

      fun when is_function(fun, 4) ->
        cond do
          Map.get(ctx, :reason) == "arbitration" and Map.get(ctx, :cross_lineage_arbitration) ->
            Fake.new([
              Fake.tool_call("forward", %{}, "call_forward"),
              Fake.report("forwarded")
            ])

          Map.get(ctx, :reason) == "arbitration" ->
            Fake.new([
              Fake.tool_call("grant", %{"reason" => "allowed"}, "call_grant"),
              Fake.report("granted")
            ])

          Map.get(ctx, :reason) in ["continuation", "retry"] and ctx.depth == 0 and
              checkpoint_has_delegate_observation?(ctx) ->
            Fake.new([fn messages -> Fake.report(delegate_result(messages)) end])

          true ->
            Fake.for_node(fun, agent_id, ctx.depth, ctx[:workspace], ctx[:team])
        end

      _ ->
        turns =
          cond do
            Map.get(ctx, :reason) == "arbitration" and Map.get(ctx, :cross_lineage_arbitration) ->
              [
                Fake.tool_call("forward", %{}, "call_forward"),
                Fake.report("forwarded")
              ]

            Map.get(ctx, :reason) == "arbitration" ->
              [
                Fake.tool_call("grant", %{"reason" => "allowed"}, "call_grant"),
                Fake.report("granted")
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
    get_in(checkpoint, ["tool_state", "counter", :value]) ||
      get_in(checkpoint, ["tool_state", "counter", "value"]) || 0
  end

  defp counter_current(_), do: 0

  defp delegate_result(messages) do
    case last_tool_result(messages, ~r/Result: (.*?)\. Still pending:/) do
      "" ->
        case last_tool_result(messages, ~r/^Result: (.+)$/) do
          "" -> "Delegation did not produce a result"
          result -> result
        end

      value ->
        value
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
