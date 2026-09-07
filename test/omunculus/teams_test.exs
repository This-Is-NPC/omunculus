defmodule Omunculus.TeamsTest do
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

  @chain_types ~w(task.requested task.delegated tool.call.requested tool.call.completed task.completed)

  @test_overlay """
  [profiles.full]
  mode = "allow"

  [profiles.ask]
  mode = "deny"
  granted = ["fs.read", "delegate"]
  instructions = "Responda. Não altere arquivos. Não delegue."

  [policy.depth.1]
  mode = "allow"
  deny = ["delegate"]
  """

  defp tmp_fixture!(base, overlay \\ nil) do
    tmp = Harness.tmp_fixture(base, overlay)
    on_exit(fn -> File.rm_rf!(tmp.dir) end)
    tmp
  end

  defp write_test_overlay!(tmp) do
    config_file =
      case tmp.overlay_path do
        nil ->
          path = Path.join(tmp.dir, "profile-full.toml")
          File.write!(path, @test_overlay)
          path

        lane_path ->
          File.write!(lane_path, File.read!(lane_path) <> "\n" <> @test_overlay)
          lane_path
      end

    {:ok, config} = Config.load(cwd: tmp.dir, config_file: config_file, env: %{})

    %{tmp | config: config, overlay_path: config_file}
  end

  defp boot_teams(tmp, opts \\ []) do
    tmp = write_test_overlay!(tmp)

    interceptors =
      Keyword.get_lazy(opts, :interceptors, fn -> resolve_interceptors(tmp) end)

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, _projector} = Projector.start_link(core: core)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: Keyword.get(opts, :max_depth, 1),
        agents: Keyword.get(opts, :agents, SpikeAgents.resolver()),
        config: [
          cwd: tmp.dir,
          config_file: tmp.overlay_path,
          env: %{},
          profile: Keyword.get(opts, :profile, "full")
        ],
        run_opts: [delegation_timeout: 10_000]
      )

    core
  end

  # Mirrors Matrix.resolve_interceptors/2 until the lane helper is public.
  defp resolve_interceptors(tmp) do
    case tmp.overlay_path do
      nil ->
        []

      _overlay ->
        tmp.config
        |> Matrix.interceptors_from_config()
        |> maybe_enrich_lane_options(tmp.config)
    end
  end

  # TeamGate needs session config in options; Matrix will inject these once the
  # TeamGate slice lands. Until then, enrich only when options are still bare.
  defp maybe_enrich_lane_options(interceptors, config) do
    Enum.map(interceptors, fn interceptor ->
      options = interceptor.options || %{}

      if Map.has_key?(options, :teams) or Map.has_key?(options, "teams") do
        interceptor
      else
        %{
          interceptor
          | options:
              Map.merge(options, %{
                teams: config.teams,
                workspaces: config.workspaces,
                agents: config.agents
              })
        }
      end
    end)
  end

  defp run_started_at(core, correlation_id, depth) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "run.started")
    |> Enum.find(&(&1.payload["depth"] == depth))
  end

  defp delegated(core, correlation_id) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id, type: "task.delegated")
    |> List.last()
  end

  defp chain_types(core, correlation_id) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id)
    |> Enum.filter(&(&1.type in @chain_types))
    |> Enum.map(& &1.type)
  end

  defp assert_agent_id(run_started, expected) do
    actual = run_started.payload["agent_id"]

    assert actual == expected or actual == "#{expected}@spike" or
             String.starts_with?(to_string(actual), expected),
           "expected agent_id #{inspect(expected)} (or #{expected}@spike), got #{inspect(actual)}"
  end

  describe "medium-teams count" do
    test "without overlay: concierge delegates to count team, counter completes" do
      tmp = tmp_fixture!("medium-teams.toml")
      core = boot_teams(tmp)

      {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

      root = run_started_at(core, requested.correlation_id, 0)
      leaf = run_started_at(core, requested.correlation_id, 1)

      assert root
      assert leaf

      assert_agent_id(root, "concierge")
      assert_agent_id(leaf, "counter")

      delegated_event = delegated(core, requested.correlation_id)
      assert delegated_event.payload["team"] == "count"
      assert leaf.payload["team"] == "count"
    end

    test "with lane.toml overlay: same result, team-gate passes, chain types match" do
      tmp_without = tmp_fixture!("medium-teams.toml")
      core_without = boot_teams(tmp_without)

      {:ok, %{result: "10", requested: requested_without}} =
        Runtime.request(core_without, "conte até 10")

      tmp_with = tmp_fixture!("medium-teams.toml", "lane.toml")
      core_with = boot_teams(tmp_with)

      {:ok, %{result: "10", requested: requested_with}} =
        Runtime.request(core_with, "conte até 10")

      stats = EventCore.interceptor_stats(core_with)
      assert %{"team-gate" => %{evaluated: evaluated, rejected: 0}} = stats
      assert evaluated > 0

      assert chain_types(core_without, requested_without.correlation_id) ==
               chain_types(core_with, requested_with.correlation_id)
    end
  end

  describe "medium-teams write README" do
    test "routes to edit team and editor agent with write tool" do
      tmp = tmp_fixture!("medium-teams.toml")
      core = boot_teams(tmp)

      {:ok, %{result: result, requested: requested}} =
        Runtime.request(core, "escrever um README")

      assert result =~ ~r/README|wrote/i

      delegated_event = delegated(core, requested.correlation_id)
      assert delegated_event.payload["team"] == "edit"

      leaf = run_started_at(core, requested.correlation_id, 1)
      assert leaf
      assert_agent_id(leaf, "editor")
      assert leaf.payload["team"] == "edit"

      granted = leaf.payload["tools"]["granted"]
      assert "write" in granted or "edit" in granted

      write_requests =
        core
        |> EventCore.stream(0,
          correlation_id: requested.correlation_id,
          type: "tool.call.requested"
        )
        |> Enum.filter(&(&1.payload["tool"] == "write"))

      assert write_requests != []
    end
  end

  describe "team profile narrows task profile" do
    test "ask profile keeps edit team leader read-only" do
      tmp = tmp_fixture!("medium-teams.toml")
      core = boot_teams(tmp, profile: "ask", max_depth: 1)

      {:ok, %{requested: requested}} =
        Runtime.request(core, "escrever um README")

      delegated_event = delegated(core, requested.correlation_id)
      assert delegated_event.payload["team"] == "edit"

      leaf = run_started_at(core, requested.correlation_id, 1)
      assert leaf

      granted = leaf.payload["tools"]["granted"]

      assert Enum.any?(granted, &(&1 in ["read", "grep", "find", "ls"]))
      refute "edit" in granted
      refute "write" in granted
    end
  end

  describe "TeamGate veto" do
    test "ghost team rejected by team-gate, no depth-1 run.started" do
      ghost_script = fn agent_id, depth, _, _ ->
        concierge? =
          depth == 0 or agent_id == "concierge" or
            (is_binary(agent_id) and String.starts_with?(agent_id, "concierge"))

        if concierge? do
          [
            Fake.tool_call("delegate", %{"instruction" => "x", "team" => "ghost"}, "d"),
            Fake.text("ok")
          ]
        else
          [Fake.text("no")]
        end
      end

      tmp = tmp_fixture!("medium-teams.toml", "lane.toml")
      core = boot_teams(tmp, agents: SpikeAgents.resolver(script: ghost_script))

      {:ok, %{requested: requested}} = Runtime.request(core, "conte até 10")

      events = EventCore.stream(core, 0, correlation_id: requested.correlation_id)

      rejection =
        Enum.find(events, fn env ->
          env.type == "delivery.rejected" and env.payload["interceptor"] == "team-gate"
        end)

      assert rejection

      depths =
        events
        |> Enum.filter(&(&1.type == "run.started"))
        |> Enum.map(& &1.payload["depth"])

      refute 1 in depths

      assert %{"team-gate" => %{rejected: rejected}} = EventCore.interceptor_stats(core)
      assert rejected > 0
    end
  end
end
