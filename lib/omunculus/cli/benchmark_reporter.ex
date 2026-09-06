defmodule Omunculus.CLI.BenchmarkReporter do
  @moduledoc false

  use GenServer

  @width 80
  @ram_bar_width 20
  @default_line_limit 24
  @states ~w(queued starting waiting_ai running_tool completed failed cancelled)a

  @type event :: %{required(:type) => atom(), optional(atom()) => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec event(pid(), event()) :: :ok
  def event(pid, event), do: GenServer.call(pid, {:event, event})

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.call(pid, :stop)

  @impl true
  def init(opts) do
    io = Keyword.get(opts, :io, :stdio)
    terminal? = Keyword.get(opts, :terminal?, terminal?(io))
    live? = terminal? and Keyword.get(opts, :live?, Keyword.get(opts, :live, true))

    {:ok,
     %{
       io: io,
       terminal?: terminal?,
       live?: live?,
       line_limit:
         opts
         |> Keyword.get(:line_limit, Keyword.get(opts, :max_lines, @default_line_limit))
         |> max(1),
       config: %{},
       level: nil,
       agents: %{},
       overflow: %{},
       metrics: %{},
       level_summary: nil,
       summary: nil
     }}
  end

  @impl true
  def handle_call({:event, %{type: :benchmark_started, config: config}}, _from, state) do
    state = %{
      state
      | config: config || %{},
        agents: %{},
        overflow: %{},
        metrics: %{},
        level: nil,
        level_summary: nil,
        summary: nil
    }

    {:reply, :ok, render(state)}
  end

  def handle_call({:event, %{type: :level_started, target: target}}, _from, state) do
    state = %{state | level: target, agents: %{}, overflow: %{}, level_summary: nil}
    {:reply, :ok, render(state)}
  end

  def handle_call({:event, %{type: :agent_updated} = event}, _from, state) do
    agent = Map.get(event, :agent, event)
    agent = normalize_agent(agent)

    {agents, overflow} =
      if Map.has_key?(state.agents, agent.id) do
        {Map.put(state.agents, agent.id, agent), state.overflow}
      else
        if map_size(state.agents) < state.line_limit do
          {Map.put(state.agents, agent.id, agent), state.overflow}
        else
          {state.agents, Map.update(state.overflow, state_name(agent.state), 1, &(&1 + 1))}
        end
      end

    # Agent updates only mutate the snapshot. Rendering happens on samples
    # and lifecycle milestones, so high-cardinality runs stay quiet.
    {:reply, :ok, %{state | agents: agents, overflow: overflow}}
  end

  def handle_call({:event, %{type: :sample, metrics: metrics}}, _from, state) do
    state = %{state | metrics: Map.merge(state.metrics, metrics || %{})}
    {:reply, :ok, render(state)}
  end

  def handle_call({:event, %{type: :level_finished, summary: summary}}, _from, state) do
    state = %{state | level_summary: summary || %{}}
    {:reply, :ok, render(state)}
  end

  def handle_call({:event, %{type: :benchmark_finished, summary: summary}}, _from, state) do
    summary =
      case value(summary, :summary) do
        nested when is_map(nested) -> nested
        _ -> summary
      end

    state = %{state | summary: summary || %{}}
    {:reply, :ok, render(state)}
  end

  def handle_call({:event, _event}, _from, state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  defp render(state) do
    output =
      state
      |> snapshot_lines()
      |> Enum.map(&render_line/1)
      |> Enum.join("\n")

    if state.live? do
      IO.write(state.io, "\e[2J\e[H" <> output <> "\n")
    else
      IO.write(state.io, output <> "\n\n")
    end

    state
  end

  defp render_line(line) do
    if String.starts_with?(line, "Summary:") or String.starts_with?(line, "Level summary:") do
      ascii(line)
    else
      clip(line)
    end
  end

  defp snapshot_lines(state) do
    details = if state.live?, do: agent_lines(state), else: []

    [
      "Omunculus benchmark",
      config_line(state.config),
      level_line(state.level),
      ram_line(state.metrics),
      counters_line(state.metrics, state.agents),
      ""
    ] ++ details ++ summary_lines(state)
  end

  defp config_line(config) do
    fields = [
      {:scenario, "scenario"},
      {:tree_mode, "tree-mode"},
      {:tree_shape, "tree-shape"},
      {:provider, "provider"},
      {:model, "model"},
      {:tools, "tools"},
      {:rounds, "rounds"},
      {:max_agents, "max-agents"},
      {:max_trees, "max-trees"},
      {:memory_limit, "memory-limit"},
      {:cpu_limit, "cpu-limit"},
      {:http_concurrency, "http-concurrency"},
      {:step, "step"},
      {:sample_ms, "sample-ms"}
    ]

    values =
      fields
      |> Enum.map(fn {key, label} ->
        case value(config, key) do
          nil -> nil
          value -> "#{label}=#{format_value(value)}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    case values do
      [] -> "Config: (waiting)"
      values -> "Config: " <> Enum.join(values, " ")
    end
  end

  defp level_line(nil), do: "Level: -"
  defp level_line(target), do: "Level: target=#{format_value(target)}"

  defp ram_line(metrics) do
    rss = integer(value(metrics, :rss_bytes), 0)
    limit = integer(value(metrics, :limit_bytes), 0)
    beam = integer(value(metrics, :beam_bytes), 0)
    filled = ram_filled(rss, limit)
    bar = String.duplicate("#", filled) <> String.duplicate(".", @ram_bar_width - filled)
    limit_text = if limit > 0, do: format_bytes(limit), else: "unlimited"
    beam_text = if beam > 0, do: " beam=#{format_bytes(beam)}", else: ""
    "RAM [#{bar}] #{format_bytes(rss)} / #{limit_text} (RSS soft limit)#{beam_text}"
  end

  defp counters_line(metrics, agents) do
    active = integer(value(metrics, :active), count_active(agents))
    completed = integer(value(metrics, :completed), count_state(agents, :completed))
    failed = integer(value(metrics, :failed), count_state(agents, :failed))
    queued = integer(value(metrics, :queued), count_state(agents, :queued))
    ready = integer(value(metrics, :ready), 0)
    active_peak = integer(value(metrics, :active_peak), active)
    processes = integer(value(metrics, :processes), 0)
    in_flight = value(metrics, :http_in_flight)
    in_flight_text = if is_nil(in_flight), do: "n/a", else: format_value(in_flight)

    "Agents: active=#{active} completed=#{completed} failed=#{failed} queued=#{queued} " <>
      "ready=#{ready} peak-active=#{active_peak} processes=#{processes} http-in-flight=#{in_flight_text}"
  end

  defp agent_lines(%{agents: agents}) when map_size(agents) == 0 do
    ["Agents: (none)"]
  end

  defp agent_lines(%{agents: agents, line_limit: limit, overflow: overflow}) do
    ordered = tree_order(agents)
    {visible, hidden} = Enum.split(ordered, limit)
    lines = Enum.map(visible, &agent_line(&1, agents))
    overflow = overflow_counts(hidden, overflow)
    hidden_count = length(hidden) + Enum.sum(Map.values(overflow))

    if hidden_count == 0 do
      lines
    else
      lines ++ [overflow_line(hidden_count, overflow)]
    end
  end

  defp overflow_counts(hidden, overflow) do
    hidden
    |> Enum.frequencies_by(fn {agent, _depth, _path} -> state_name(agent.state) end)
    |> Map.merge(overflow, fn _state, left, right -> left + right end)
  end

  defp tree_order(agents) do
    values = Map.values(agents)
    ids = MapSet.new(values, & &1.id)
    by_parent = Enum.group_by(values, & &1.parent_id)

    roots =
      values
      |> Enum.filter(fn agent ->
        is_nil(agent.parent_id) or not MapSet.member?(ids, agent.parent_id)
      end)
      |> sort_agents()

    root_count = length(roots)

    roots
    |> Enum.with_index()
    |> Enum.flat_map(fn {root, index} ->
      walk_tree(root, by_parent, 0, [index == root_count - 1])
    end)
  end

  defp walk_tree(agent, by_parent, depth, path) do
    children = by_parent |> Map.get(agent.id, []) |> sort_agents()
    child_count = length(children)

    descendants =
      children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        walk_tree(child, by_parent, depth + 1, path ++ [index == child_count - 1])
      end)

    [{agent, depth, path} | descendants]
  end

  defp sort_agents(agents), do: Enum.sort_by(agents, &sortable_id(&1.id))

  defp sortable_id(id), do: id |> format_value() |> String.downcase()

  defp agent_line({agent, depth, path}, agents) do
    tree =
      case depth do
        0 ->
          ""

        1 ->
          "   "

        _ ->
          path
          |> Enum.drop(-1)
          |> Enum.map_join(fn last? -> if last?, do: "   ", else: "|  " end)
      end

    marker =
      cond do
        depth == 0 -> "|-"
        List.last(path) -> "`-"
        true -> "|-"
      end

    state = state_name(agent.state)
    round = if is_nil(agent.round), do: nil, else: " round=#{format_value(agent.round)}"
    tool = if is_nil(agent.tool), do: nil, else: " tool=#{format_value(agent.tool)}"
    parent = unknown_parent(agent, agents)
    "#{tree}#{marker} #{format_value(agent.id)} [#{state}]#{round || ""}#{tool || ""}#{parent}"
  end

  defp unknown_parent(%{parent_id: nil}, _agents), do: ""

  defp unknown_parent(%{parent_id: parent_id}, agents) do
    if Map.has_key?(agents, parent_id), do: "", else: " parent=#{format_value(parent_id)}"
  end

  defp overflow_line(hidden_count, overflow) do
    details =
      overflow
      |> Enum.sort_by(fn {state, _count} -> state end)
      |> Enum.map_join(", ", fn {state, count} -> "#{count} #{state}" end)

    "... #{hidden_count} more (#{details})"
  end

  defp summary_lines(%{level_summary: nil, summary: nil}), do: []

  defp summary_lines(state) do
    level =
      if state.level_summary, do: [summary_line("Level summary", state.level_summary)], else: []

    final = if state.summary, do: [summary_line("Summary", state.summary)], else: []
    level ++ final
  end

  defp summary_line(label, summary) do
    fields = [
      {:scenario, "scenario"},
      {:synthetic, "synthetic"},
      {:tree_mode, "tree_mode"},
      {:tree_shape, "tree_shape"},
      {:target, "target"},
      {:trees, "trees"},
      {:nodes, "nodes"},
      {:edges, "edges"},
      {:agent_executions, "agent_executions"},
      {:durable_runs_observed, "durable_runs_observed"},
      {:to_be_runs_expected, "to_be_runs_expected"},
      {:depth_counts, "depth_counts"},
      {:ready, "ready"},
      {:active_peak, "active_peak"},
      {:completed, "completed"},
      {:failed, "failed"},
      {:over, "over"},
      {:over_limit?, "over_limit"},
      {:valid?, "valid"},
      {:baseline, "baseline"},
      {:peak, "peak"},
      {:max_good, "max_good"},
      {:max_good_trees, "max_good_trees"},
      {:max_good_agents, "max_good_agents"},
      {:stop_reason, "stop_reason"}
    ]

    values =
      fields
      |> Enum.map(fn {key, name} ->
        case value(summary, key) do
          nil -> nil
          value -> "#{name}=#{format_value(value)}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    per_agent =
      case value(summary, :per_agent) do
        map when is_map(map) -> per_agent_text(map)
        _ -> nil
      end

    values = if per_agent, do: values ++ [per_agent], else: values
    "#{label}: " <> if(values == [], do: "done", else: Enum.join(values, " "))
  end

  defp per_agent_text(per_agent) do
    if Map.has_key?(per_agent, :slope_bytes) or Map.has_key?(per_agent, "slope_bytes") or
         Map.has_key?(per_agent, :estimate_bytes) or Map.has_key?(per_agent, "estimate_bytes") do
      direct_per_agent_text(per_agent)
    else
      per_agent
      |> Enum.map_join(" ", fn {id, details} ->
        slope = value(details, :slope_bytes)
        estimate = value(details, :estimate_bytes)
        parts = ["#{format_value(id)}:"]
        parts = if is_nil(slope), do: parts, else: parts ++ ["slope=#{format_value(slope)}"]

        parts =
          if is_nil(estimate),
            do: parts,
            else: parts ++ ["estimate=#{format_value(estimate)}"]

        Enum.join(parts, " ")
      end)
      |> case do
        "" -> nil
        text -> text
      end
    end
  end

  defp direct_per_agent_text(per_agent) do
    parts = []
    slope = value(per_agent, :slope_bytes)
    estimate = value(per_agent, :estimate_bytes)
    parts = if is_nil(slope), do: parts, else: parts ++ ["slope=#{format_value(slope)}"]
    parts = if is_nil(estimate), do: parts, else: parts ++ ["estimate=#{format_value(estimate)}"]
    if parts == [], do: nil, else: Enum.join(parts, " ")
  end

  defp normalize_agent(agent) when is_map(agent) do
    id = value(agent, :id) || "?"

    %{
      id: id,
      parent_id: value(agent, :parent_id),
      state: value(agent, :state) || :queued,
      round: value(agent, :round),
      tool: value(agent, :tool),
      started_at_ms: value(agent, :started_at_ms)
    }
  end

  defp normalize_agent(_), do: normalize_agent(%{})

  defp state_name(state) when state in @states, do: Atom.to_string(state)
  defp state_name(state) when is_atom(state), do: Atom.to_string(state)
  defp state_name(state), do: format_value(state)

  defp count_active(agents),
    do:
      Enum.count(agents, fn {_id, agent} ->
        state_name(agent.state) in ~w(starting waiting_ai running_tool)
      end)

  defp count_state(agents, state),
    do: Enum.count(agents, fn {_id, agent} -> agent.state == state end)

  defp ram_filled(_rss, limit) when limit <= 0, do: 0
  defp ram_filled(rss, limit), do: min(@ram_bar_width, max(0, div(rss * @ram_bar_width, limit)))

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1_024)} KiB"
  defp format_bytes(bytes) when bytes < 1_073_741_824, do: "#{div(bytes, 1_048_576)} MiB"
  defp format_bytes(bytes), do: "#{div(bytes, 1_073_741_824)} GiB"

  defp format_value(value) when is_binary(value), do: ascii(value)
  defp format_value(value) when is_atom(value), do: value |> Atom.to_string() |> ascii()
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: value |> inspect() |> ascii()

  defp ascii(value) do
    value
    |> String.to_charlist()
    |> Enum.map(fn codepoint -> if codepoint in 32..126, do: codepoint, else: ?? end)
    |> List.to_string()
  end

  defp clip(value) do
    value = ascii(value)
    if byte_size(value) <= @width, do: value, else: binary_part(value, 0, @width - 3) <> "..."
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil

  defp integer(value, _fallback) when is_integer(value), do: value
  defp integer(value, _fallback) when is_float(value), do: trunc(value)
  defp integer(_, fallback), do: fallback

  defp terminal?(:stdio), do: match?({:ok, _}, :io.columns(:standard_io))
  defp terminal?(:stderr), do: match?({:ok, _}, :io.columns(:standard_error))
  defp terminal?(:stdout), do: match?({:ok, _}, :io.columns(:standard_io))
  defp terminal?(_), do: false
end
