defmodule Omunculus.PolicyRuntimeTest do
  use ExUnit.Case, async: true

  import ExUnit.Assertions

  alias Omunculus.Chat.Fake
  alias Omunculus.Config
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Harness
  alias Omunculus.Matrix
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  defp tmp_fixture!(base, overlay \\ nil) do
    tmp = Harness.tmp_fixture(base, overlay)
    on_exit(fn -> File.rm_rf!(tmp.dir) end)
    tmp
  end

  defp boot_policy(tmp, max_depth, opts \\ []) do
    interceptors =
      Keyword.get_lazy(opts, :interceptors, fn ->
        Matrix.interceptors_from_config(tmp.config)
      end)

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: max_depth,
        agents: Keyword.get(opts, :agents, SpikeAgents.resolver()),
        config: [
          cwd: tmp.dir,
          config_file: tmp.path,
          env: %{},
          profile: Keyword.get(opts, :profile, "count")
        ],
        run_opts: [delegation_timeout: 10_000]
      )

    %{core: core, projector: projector, runtime: runtime}
  end

  defp run_started_at(core, correlation_id, depth) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "run.started")
    |> Enum.find(&(&1.payload["depth"] == depth))
  end

  defp granted_tools(run_started) do
    get_in(run_started.payload, ["tools", "granted"]) || []
  end

  defp tool_requests(core, correlation_id, tool) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "tool.call.requested")
    |> Enum.filter(&(&1.payload["tool"] == tool))
  end

  describe "simple.toml count at depth 0" do
    test "without overlay: counter granted, not write" do
      tmp = tmp_fixture!("simple.toml")
      %{core: core} = boot_policy(tmp, 0)

      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      root = run_started_at(core, requested.correlation_id, 0)
      granted = granted_tools(root)

      assert "counter" in granted
      refute "write" in granted
    end

    test "with lane.toml overlay: tool-gate evaluates, chain matches depth 0" do
      tmp = tmp_fixture!("simple.toml", "lane.toml")
      %{core: core} = boot_policy(tmp, 0)

      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      root = run_started_at(core, requested.correlation_id, 0)
      granted = granted_tools(root)

      assert "counter" in granted
      refute "write" in granted

      stats = EventCore.interceptor_stats(core)
      assert %{"tool-gate" => %{evaluated: n, rejected: 0}} = stats
      assert n > 0

      events =
        core
        |> EventCore.stream(0, correlation_id: requested.correlation_id)
        |> Enum.filter(
          &(&1.type in ~w(task.requested tool.call.requested tool.call.completed task.completed))
        )
        |> Enum.map(& &1.type)

      assert events ==
               ["task.requested"] ++
                 List.flatten(List.duplicate(["tool.call.requested", "tool.call.completed"], 10)) ++
                 ["task.completed"]
    end
  end

  describe "medium.toml count at depth 1" do
    test "without overlay: delegate at depth 0, counter at leaf" do
      tmp = tmp_fixture!("medium.toml")
      %{core: core} = boot_policy(tmp, 1)

      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      root = run_started_at(core, requested.correlation_id, 0)
      leaf = run_started_at(core, requested.correlation_id, 1)

      assert "delegate" in granted_tools(root)
      refute "counter" in granted_tools(root)
      assert "counter" in granted_tools(leaf)
      refute "delegate" in granted_tools(leaf)
    end

    test "with lane.toml overlay: same result and tool pinning" do
      tmp = tmp_fixture!("medium.toml", "lane.toml")
      %{core: core} = boot_policy(tmp, 1)

      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      root = run_started_at(core, requested.correlation_id, 0)
      leaf = run_started_at(core, requested.correlation_id, 1)

      assert "delegate" in granted_tools(root)
      refute "counter" in granted_tools(root)
      assert "counter" in granted_tools(leaf)
      refute "delegate" in granted_tools(leaf)

      stats = EventCore.interceptor_stats(core)
      assert %{"tool-gate" => %{evaluated: n, rejected: 0}} = stats
      assert n > 0
    end
  end

  describe "write README with coding profile" do
    test "simple.toml depth 0 writes README via pinned write tool" do
      tmp = tmp_fixture!("simple.toml")
      agents = Matrix.write_agents("write README", 0)

      %{core: core} = boot_policy(tmp, 0, profile: "coding", agents: agents)

      {:ok, %{result: result, requested: requested}} = Runtime.request(core, "write README")

      assert result =~ ~r/README|wrote/i

      [write_req] = tool_requests(core, requested.correlation_id, "write")
      assert write_req

      root = run_started_at(core, requested.correlation_id, 0)
      granted = granted_tools(root)
      assert "write" in granted or "edit" in granted
    end

    test "medium.toml depth 1: concierge delegates, worker writes" do
      tmp = tmp_fixture!("medium.toml")
      agents = Matrix.write_agents("write README", 1)

      %{core: core} = boot_policy(tmp, 1, profile: "coding", agents: agents)

      {:ok, %{result: result, requested: requested}} = Runtime.request(core, "write README")

      assert result =~ ~r/README|wrote/i

      assert Enum.any?(
               EventCore.stream(core, 0, correlation_id: requested.correlation_id),
               &(&1.type == "task.delegated")
             )

      assert [_write] = tool_requests(core, requested.correlation_id, "write")
    end
  end

  describe "hot reload" do
    test "second run picks up appended profile tools without mutating the first run.started" do
      tmp = tmp_fixture!("simple.toml")
      %{core: core} = boot_policy(tmp, 0)

      {:ok, %{requested: first}} = Runtime.request(core, "conte até 2")

      first_started = run_started_at(core, first.correlation_id, 0)
      first_tools = first_started.payload["tools"]

      File.write!(
        tmp.path,
        String.replace(
          File.read!(tmp.path),
          "granted = [\"counter\"]",
          "granted = [\"counter\", \"write\"]",
          global: false
        )
      )

      {:ok, %{requested: second}} = Runtime.request(core, "conte até 2")

      second_started = run_started_at(core, second.correlation_id, 0)
      second_tools = second_started.payload["tools"]

      assert second_tools != first_tools or
               length(EventCore.stream(core, 0, type: "policy.loaded")) >= 2

      replayed_first =
        core
        |> EventCore.stream(0, correlation_id: first.correlation_id, type: "run.started")
        |> Enum.find(&(&1.event_id == first_started.event_id))

      assert replayed_first.payload["tools"] == first_tools
    end
  end

  describe "ask profile barriers with ToolGate" do
    test "--profile ask rejects edit at delivery while coding would allow it" do
      {:ok, lane_config} =
        Config.load(
          cwd: Harness.fixtures_dir(),
          config_file: Path.join(Harness.fixtures_dir(), "lane.toml"),
          env: %{}
        )

      lane_interceptors = Matrix.interceptors_from_config(lane_config)

      tmp = tmp_fixture!("simple.toml")

      File.write!(
        tmp.path,
        File.read!(tmp.path) <>
          "\n[profiles.ask]\nmode = \"deny\"\ngranted = [\"fs.read\"]\ninstructions = \"do not edit\"\n"
      )

      ask_agents =
        SpikeAgents.resolver(
          script: fn _agent_id, _depth, _, _ ->
            [
              Fake.tool_call("edit", %{"path" => "README.md", "content" => "nope"}, "call_edit"),
              Fake.text("done")
            ]
          end
        )

      %{core: core} =
        boot_policy(tmp, 0, profile: "ask", agents: ask_agents, interceptors: lane_interceptors)

      {:ok, %{requested: requested}} = Runtime.request(core, "touch README")

      correlation_id = requested.correlation_id
      root = run_started_at(core, correlation_id, 0)
      granted = granted_tools(root)

      refute "edit" in granted

      [edit_req] = tool_requests(core, correlation_id, "edit")

      rejection =
        core
        |> EventCore.stream(0, correlation_id: correlation_id)
        |> Enum.find(fn env ->
          env.type == "delivery.rejected" and
            env.payload["rejected_event_id"] == edit_req.event_id
        end)

      assert rejection.payload["interceptor"] == "tool-gate"

      refute Enum.any?(
               EventCore.stream(core, 0,
                 correlation_id: correlation_id,
                 type: "tool.call.completed"
               ),
               fn env ->
                 env.payload["tool"] == "edit" and env.payload["outcome"] == "completed"
               end
             )

      coding_tmp = tmp_fixture!("simple.toml")
      coding_agents = Matrix.write_agents("write README", 0)
      %{core: coding_core} = boot_policy(coding_tmp, 0, profile: "coding", agents: coding_agents)
      {:ok, %{requested: coding_req}} = Runtime.request(coding_core, "write README")
      coding_root = run_started_at(coding_core, coding_req.correlation_id, 0)
      assert "write" in granted_tools(coding_root) or "edit" in granted_tools(coding_root)
    end
  end
end
