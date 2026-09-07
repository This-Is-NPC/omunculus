defmodule Omunculus.Matrix do
  @moduledoc false

  import ExUnit.Assertions

  alias Omunculus.Chat.Fake
  alias Omunculus.{Harness, Interceptor}
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  @chain_types ~w(task.requested task.delegated tool.call.requested tool.call.completed task.completed)

  def simple(base \\ "simple.toml", overlay \\ nil, task \\ "conte até 10") do
    run(0, base, overlay, task, pass_config: true)
  end

  def medium(base \\ "medium.toml", overlay \\ nil, task \\ "conte até 10") do
    run(1, base, overlay, task)
  end

  def skipped_lane_modules(base \\ "medium.toml", overlay \\ "lane.toml") do
    %{config: config} = Harness.tmp_fixture(base, overlay)

    config.interceptors
    |> Enum.map(&(&1.module || ""))
    |> Enum.filter(fn module ->
      match?({:error, _}, Interceptor.resolve(module))
    end)
    |> Enum.sort()
  end

  def complex(base \\ "complex.toml", overlay \\ nil, task \\ "conte até 10") do
    run(2, base, overlay, task)
  end

  def invariants!(ctx) do
    assert_chain!(ctx)
    assert_replay!(ctx)
    assert_redelivery!(ctx)
    assert_tools!(ctx)

    if ctx.overlay do
      assert_interceptor_stats!(ctx)
    end

    :ok
  end

  def assert_chain!(%{events: events, depth: depth}) do
    assert Enum.map(events, & &1.type) == expected_types(depth)
    assert hd(events).causation_id == nil
    assert_linear!(events)
  end

  def assert_replay!(%{core: core, projector: projector}) do
    :ok = Projector.sync(projector)

    before = Projector.snapshot(core)
    cursor = Projector.cursor(projector)

    :ok = Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
    assert Projector.cursor(projector) == cursor
  end

  def assert_redelivery!(%{core: core, projector: projector, correlation_id: correlation_id}) do
    :ok = Projector.sync(projector)

    count = length(EventCore.stream(core, 0))
    before = Projector.snapshot(core)

    for env <- EventCore.stream(core, 0, correlation_id: correlation_id) do
      assert {:ok, ^env} = EventCore.append(core, env)
    end

    :ok = Projector.sync(projector)
    assert length(EventCore.stream(core, 0)) == count
    assert Projector.snapshot(core) == before
  end

  def assert_tools!(%{core: core, correlation_id: correlation_id}) do
    depths = run_depths(core, correlation_id)
    leaf = Enum.max(Map.values(depths))

    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "tool.call.requested")
    |> Enum.each(fn env ->
      depth = Map.fetch!(depths, env.run_id)
      tool = env.payload["tool"]

      if depth == leaf do
        assert tool == "counter"
      else
        assert tool == "delegate"
      end
    end)
  end

  def assert_interceptor_stats!(%{core: core, depth: depth}) do
    stats = EventCore.interceptor_stats(core)

    assert %{"audit" => %{evaluated: audit_evaluated, rejected: 0}} = stats
    assert audit_evaluated > 0

    assert %{"depth-gate" => %{evaluated: gate_evaluated, rejected: 0}} = stats

    if depth > 0 do
      assert gate_evaluated > 0
    end

    assert %{"tool-gate" => %{evaluated: tool_evaluated, rejected: 0}} = stats
    assert tool_evaluated > 0
  end

  def interceptors_from_config(config) do
    config.interceptors
    |> Enum.map(&resolve_interceptor/1)
    |> Enum.reject(&is_nil/1)
  end

  def profile_for(task) do
    if Regex.match?(~r/README|escrever|write/i, task), do: "coding", else: "count"
  end

  def write_agents(_task, max_depth) do
    worker_script = fn _agent_id, depth, _, _ ->
      if depth >= max_depth do
        [
          Fake.tool_call("write", %{"path" => "README.md", "content" => "# hi\n"}, "call_write"),
          Fake.text("wrote README")
        ]
      else
        [fn _msgs -> Fake.text("") end]
      end
    end

    worker_resolver = SpikeAgents.resolver(script: worker_script)

    fn ctx ->
      if ctx.depth < max_depth do
        SpikeAgents.resolve(ctx, %{})
      else
        worker_resolver.(ctx)
      end
    end
  end

  defp run(depth, base, overlay, task, opts \\ []) do
    pass_config? = Keyword.get(opts, :pass_config, false)
    {interceptors, runtime_config, agents} = boot_params(depth, base, overlay, task, pass_config?)

    %{core: core, projector: projector, runtime: runtime} =
      boot(depth, interceptors, config: runtime_config, agents: agents)

    {:ok, %{result: result, requested: requested}} = Runtime.request(core, task)

    Harness.await_log(core, fn env ->
      env.type == "task.completed" and env.payload["depth"] == 0
    end)

    correlation_id = requested.correlation_id
    events = chain(core, correlation_id)

    %{
      core: core,
      projector: projector,
      runtime: runtime,
      correlation_id: correlation_id,
      result: result,
      types: Enum.map(events, & &1.type),
      events: events,
      depth: depth,
      overlay: overlay
    }
  end

  defp boot_params(depth, base, overlay, task, true) do
    tmp = Harness.tmp_fixture(base, overlay)
    interceptors = if overlay, do: interceptors_from_config(tmp.config), else: []

    config = [
      cwd: tmp.dir,
      config_file: tmp.overlay_path || tmp.path,
      env: %{},
      profile: profile_for(task)
    ]

    agents = if write_task?(task), do: write_agents(task, depth), else: SpikeAgents.resolver()
    {interceptors, config, agents}
  end

  defp boot_params(_depth, base, overlay, _task, false) do
    {resolve_interceptors(base, overlay), nil, SpikeAgents.resolver()}
  end

  defp boot(max_depth, interceptors, opts) do
    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)

    runtime_opts = [
      core: core,
      max_depth: max_depth,
      agents: Keyword.fetch!(opts, :agents),
      run_opts: [delegation_timeout: 10_000]
    ]

    runtime_opts =
      case Keyword.get(opts, :config) do
        nil -> runtime_opts
        config -> Keyword.put(runtime_opts, :config, config)
      end

    {:ok, runtime} = Runtime.start_link(runtime_opts)

    %{core: core, projector: projector, runtime: runtime}
  end

  defp resolve_interceptors(_base, nil), do: []

  defp resolve_interceptors(base, overlay) when is_binary(overlay) do
    %{config: config} = Harness.tmp_fixture(base, overlay)
    interceptors_from_config(config)
  end

  defp resolve_interceptor(item) do
    module_name = item.module || ""

    case Interceptor.resolve(module_name) do
      {:ok, module} ->
        %{
          name: item.name,
          events: item.events,
          module: module,
          options: item.options
        }

      {:error, _} ->
        nil
    end
  end

  defp chain(core, correlation_id) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id)
    |> Enum.filter(&(&1.type in @chain_types))
  end

  defp assert_linear!(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [prev, next] ->
      assert next.causation_id == prev.event_id,
             "#{next.type} (#{next.event_id}) should be caused by #{prev.type} (#{prev.event_id})"
    end)
  end

  defp expected_types(depth, rounds \\ 10) do
    ["task.requested"] ++
      List.duplicate("task.delegated", depth) ++
      List.flatten(List.duplicate(["tool.call.requested", "tool.call.completed"], rounds)) ++
      List.duplicate("task.completed", depth + 1)
  end

  defp run_depths(core, correlation_id) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "run.started")
    |> Map.new(fn env -> {env.run_id, env.payload["depth"]} end)
  end

  defp write_task?(task), do: Regex.match?(~r/README|escrever|write/i, task)
end
