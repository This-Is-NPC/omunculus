defmodule Omunculus.BenchmarkTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Omunculus.Benchmark
  alias Omunculus.Benchmark.Stub

  setup_all do
    assert {:ok, stub} = Stub.start(timeout: 10_000)
    Stub.stop(stub)
    :ok
  end

  test "requires a concurrency or memory limit" do
    assert {:error, {:usage, :benchmark_limit_required}} = Benchmark.run(%{})
  end

  test "runs deterministic stub levels for one and two agents" do
    parent = self()

    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               max_agents: 2,
               sample_ms: 5,
               reporter: fn event -> send(parent, {:benchmark_event, event}) end
             })

    assert summary.runtime == :current_runtime
    assert summary.max_good == 2
    assert summary.stop_reason == :max_agents
    assert Enum.map(summary.levels, & &1.target) == [1, 2]

    assert Enum.all?(summary.levels, fn level ->
             level.ready == level.target and
               level.active_peak == level.target and
               level.completed == level.target and
               level.failed == 0 and
               level.valid?
           end)

    assert_receive {:benchmark_event, %{type: :benchmark_started}}
    assert_receive {:benchmark_event, %{type: :benchmark_finished}}
    refute_receive {:benchmark_event, %{type: :http_request}}
  end

  test "runs a resident tree plateau with stable topology metrics" do
    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               scenario: :agent_tree,
               max_trees: 1,
               sample_ms: 5,
               live: false
             })

    assert summary.synthetic
    assert summary.tree_mode == :resident
    assert summary.tree_shape == [1, 1, 2, 4]
    assert summary.max_good_trees == 1
    assert summary.max_good_agents == 8
    assert summary.nodes == 8
    assert summary.edges == 7
    assert summary.agent_executions == 8
    assert summary.durable_runs_observed == 0
    assert summary.to_be_runs_expected == 12
    refute Map.has_key?(summary, :runs)
    assert summary.depth_counts == [1, 1, 2, 4]
    assert summary.ready == 8
    assert summary.active_peak == 8
    assert summary.failed == 0
    refute summary.over
    assert summary.stop_reason == :max_trees

    assert [
             %{
               nodes: 8,
               edges: 7,
               agent_executions: 8,
               durable_runs_observed: 0,
               to_be_runs_expected: 12,
               over: false,
               valid?: true
             }
           ] = summary.levels
  end

  test "rejects unsupported tree modes and invalid shapes" do
    assert {:error, {:usage, {:invalid_tree_mode, :durable}}} =
             Benchmark.run(%{scenario: :agent_tree, max_trees: 1, tree_mode: :durable})

    assert {:error, {:usage, {:invalid_tree_shape, [1, 2, 3]}}} =
             Benchmark.run(%{scenario: :agent_tree, max_trees: 1, tree_shape: [1, 2, 3]})
  end

  test "restores scheduler count after resident tree run" do
    previous = System.schedulers_online()
    limit = min(previous, 1)

    assert {:ok, _result} =
             Benchmark.run(%{
               scenario: :agent_tree,
               max_trees: 1,
               cpu_limit: limit,
               sample_ms: 5,
               live: false
             })

    assert System.schedulers_online() == previous
  end

  test "reports partial resident tree levels when RSS is already over limit" do
    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               scenario: :agent_tree,
               max_trees: 2,
               memory_limit: 1,
               sample_ms: 5,
               live: false
             })

    assert summary.max_good_trees == 0
    assert summary.over
    assert summary.stop_reason == :memory_limit
    assert summary.nodes < 8
    assert summary.ready <= summary.nodes
    assert [%{target: 1, valid?: false, over: true}] = summary.levels
  end

  test "stops a large tree shape before spawning when the RSS limit is low" do
    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               scenario: :agent_tree,
               max_trees: 100_000,
               tree_shape: [1, 100_000, 1_000_000],
               memory_limit: 1,
               sample_ms: 5,
               live: false
             })

    assert summary.max_good_trees == 0
    assert summary.max_good_agents == 0
    assert summary.nodes == 0
    assert summary.edges == 0
    assert summary.stop_reason == :memory_limit
    assert [%{target: 1, nodes: 0, valid?: false}] = summary.levels
    refute Map.has_key?(summary, :runs)
  end

  test "ramps resident trees geometrically and preserves parent links" do
    parent = self()

    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               scenario: :agent_tree,
               max_trees: 2,
               tree_shape: [1, 1, 2],
               sample_ms: 5,
               live: true,
               reporter: fn event -> send(parent, {:tree_event, event}) end
             })

    assert summary.max_good_trees == 2
    assert summary.max_good_agents == 8
    updates = collect_tree_updates([])
    assert Enum.count(updates) == 24
    agents = updates
    ids = MapSet.new(agents, & &1.id)

    assert Enum.all?(agents, fn %{parent_id: parent_id, depth: depth, path: path, id: id} ->
             String.ends_with?(id, "/" <> path) and
               depth == length(String.split(path, ".")) - 1 and
               (is_nil(parent_id) or MapSet.member?(ids, parent_id))
           end)
  end

  defp collect_tree_updates(acc) do
    receive do
      {:tree_event, %{type: :agent_updated, agent: agent}} -> collect_tree_updates([agent | acc])
    after
      100 -> acc
    end
  end

  test "cancels in-flight HTTP work on the first over-limit sample" do
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               scenario: :http_load,
               max_agents: 1,
               memory_limit: 1,
               stub_delay_ms: 2_000,
               sample_ms: 5
             })

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_500
    assert summary.max_good == 0
    assert [%{completed: 0, failed: 0, over_limit?: true, valid?: false}] = summary.levels
  end

  test "stops at an already exceeded soft RSS limit" do
    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               max_agents: 2,
               memory_limit: 1,
               stub_delay_ms: 20,
               sample_ms: 5
             })

    assert summary.max_good == 0
    assert summary.stop_reason == :memory_limit
    assert [%{target: 1, over_limit?: true}] = summary.levels
  end

  test "samples a busy density mailbox before all workers are ready" do
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{
               max_agents: 2_048,
               step: 2_048,
               memory_limit: 1,
               sample_ms: 1,
               live: false
             })

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_500
    assert summary.max_good == 0
    assert summary.stop_reason == :memory_limit

    assert [
             %{
               target: 2_048,
               ready: ready,
               active_peak: active_peak,
               over_limit?: true,
               valid?: false
             }
           ] = summary.levels

    assert ready < 2_048
    assert active_peak < 2_048
  end

  test "writes JSON summary and removes temporary artifact" do
    path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-benchmark-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{summary: %{max_good: 1}}} =
             Benchmark.run(%{max_agents: 1, json: path, sample_ms: 5})

    json = path |> File.read!() |> Jason.decode!()
    assert json["summary"]["runtime"] == "current_runtime"
    assert json["summary"]["max_good"] == 1

    assert :ok = File.rm(path)
    refute File.exists?(path)
  end

  test "external stub returns final responses and bounded counter tool loop" do
    {:ok, stub} = Stub.start(rounds: 2)
    on_exit(fn -> Stub.stop(stub) end)

    base = stub.base_url
    request = %{model: "benchmark", messages: [%{role: "user", content: "ping"}]}

    assert {:ok, response} = Req.post(base <> "/v1/chat/completions", json: request)
    assert response.status == 200

    assert get_in(response.body, ["choices", Access.at(0), "message", "content"]) ==
             "benchmark complete"

    tool = %{
      type: "function",
      function: %{name: "counter", description: "counter", parameters: %{type: "object"}}
    }

    assert {:ok, first} =
             Req.post(base <> "/v1/chat/completions",
               json: Map.put(request, :tools, [tool])
             )

    assert get_in(first.body, ["choices", Access.at(0), "message", "tool_calls"]) != nil

    messages =
      request.messages ++ [%{role: "assistant", content: nil, tool_calls: [%{id: "call-1"}]}]

    assert {:ok, second} =
             Req.post(base <> "/v1/chat/completions",
               json: %{model: "benchmark", messages: messages, tools: [tool]}
             )

    assert get_in(second.body, ["choices", Access.at(0), "message", "tool_calls"]) != nil

    messages =
      messages ++
        [
          %{role: "tool", content: "Counter value: 1", tool_call_id: "call-1"},
          %{role: "tool", content: "Counter value: 2", tool_call_id: "call-2"}
        ]

    assert {:ok, final} =
             Req.post(base <> "/v1/chat/completions",
               json: %{model: "benchmark", messages: messages, tools: [tool]}
             )

    assert get_in(final.body, ["choices", Access.at(0), "message", "content"]) ==
             "benchmark complete"

    assert {:ok, stats} = Req.get(base <> "/stats")
    assert stats.body["requests"] == 4
    assert stats.body["tool_requests"] == 2
  end

  test "CLI reports missing benchmark limit without starting provider" do
    stderr =
      capture_io(:stderr, fn ->
        result = Omunculus.CLI.dispatch(["benchmark", "--no-live"], %{})
        Process.put(:benchmark_cli_code, result)
      end)

    code = Process.delete(:benchmark_cli_code)
    assert code == 2
    assert stderr =~ "benchmark requires --max-agents or --memory-limit"
  end

  test "always includes the final maximum in linear ramp targets" do
    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{max_agents: 5, step: 2, sample_ms: 5})

    assert Enum.map(summary.levels, & &1.target) == [2, 4, 5]

    assert {:ok, %{summary: summary}} =
             Benchmark.run(%{max_agents: 2, step: 5, sample_ms: 5})

    assert Enum.map(summary.levels, & &1.target) == [2]
  end

  test "rejects unknown and mixed benchmark tools" do
    assert {:error, {:usage, {:invalid_tools, ["unknown"]}}} =
             Benchmark.run(%{max_agents: 1, tools: "unknown"})

    assert {:error, {:usage, {:invalid_tools, ["counter", "unknown"]}}} =
             Benchmark.run(%{max_agents: 1, tools: "counter,unknown"})

    assert {:error, {:usage, {:invalid_tools, [{"unknown"}]}}} =
             Benchmark.run(%{max_agents: 1, tools: [{"unknown"}]})
  end

  test "marks HTTP in-flight telemetry unavailable when it is not measured" do
    assert {:ok, %{summary: summary}} = Benchmark.run(%{max_agents: 1, sample_ms: 5})
    assert summary.baseline.http_in_flight == nil
    assert summary.peak.http_in_flight == nil
  end

  test "reports real per-agent byte fields" do
    assert {:ok, %{summary: %{per_agent: per_agent}}} =
             Benchmark.run(%{max_agents: 1, sample_ms: 5})

    assert %{slope_bytes: slope, estimate_bytes: estimate} = per_agent
    assert is_float(slope)
    assert is_integer(estimate)
  end

  test "passes benchmark environment to config without making a provider request" do
    path =
      Path.join(
        System.tmp_dir!(),
        "omunculus-benchmark-config-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(
      path,
      "[chat]\napi = \"${BENCHMARK_API}\"\nmodel = \"model\"\nbase_url = \"unused\"\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert {:error, {:unsupported_api, "unsupported"}} =
             Benchmark.run(%{
               max_agents: 1,
               provider: :real,
               config: path,
               env: %{"BENCHMARK_API" => "unsupported"}
             })
  end
end
