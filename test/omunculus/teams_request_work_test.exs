defmodule Omunculus.TeamsRequestWorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.Chat.Fake
  alias Omunculus.Config
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Harness
  alias Omunculus.Matrix
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  @delegation_overlay """
  [profiles.delegating]
  mode = "allow"
  deny = ["counter"]
  """

  defp tmp_fixture!(base, overlay \\ nil) do
    tmp = Harness.tmp_fixture(base, overlay)
    on_exit(fn -> File.rm_rf!(tmp.dir) end)
    tmp
  end

  defp enrich_lane_options(interceptors, config) do
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

  defp boot_complex(tmp, opts) do
    config_file =
      case tmp.overlay_path do
        nil ->
          path = Path.join(tmp.dir, "delegation.toml")
          File.write!(path, File.read!(tmp.path) <> "\n" <> @delegation_overlay)
          path

        lane_path ->
          File.write!(lane_path, File.read!(lane_path) <> "\n" <> @delegation_overlay)
          lane_path
      end

    {:ok, config} = Config.load(cwd: tmp.dir, config_file: config_file, env: %{})
    tmp = %{tmp | config: config, overlay_path: config_file}

    interceptors =
      Keyword.get_lazy(opts, :interceptors, fn ->
        case tmp.overlay_path do
          nil -> []
          _ -> tmp.config |> Matrix.interceptors_from_config() |> enrich_lane_options(tmp.config)
        end
      end)

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, _projector} = Projector.start_link(core: core)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: Keyword.get(opts, :max_depth, 2),
        agents: Keyword.get(opts, :agents, SpikeAgents.resolver()),
        config: [cwd: tmp.dir, config_file: config_file, env: %{}, profile: "delegating"],
        run_opts: [delegation_timeout: 15_000]
      )

    core
  end

  defp cross_team_script(agent_id, depth, _ws, team, reason) do
    cond do
      depth == 0 and reason != "arbitration" ->
        [
          Fake.tool_call("delegate", %{"instruction" => "review", "workspace" => "app", "team" => "code-review"}, "d0"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call("delegate", %{"instruction" => "scan", "agent" => "security-reviewer"}, "d1"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call("request_work", %{"instruction" => "style pass", "team" => "edit", "agent" => "editor"}, "rw"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "editor" -> [Fake.text("edited")]
      true -> [Fake.text("ok")]
    end
  end

  defp sibling_script(agent_id, depth, _ws, team, reason) do
    cond do
      depth == 0 and reason != "arbitration" ->
        [
          Fake.tool_call("delegate", %{"instruction" => "review", "workspace" => "app", "team" => "code-review"}, "d0"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call("delegate", %{"instruction" => "scan", "agent" => "security-reviewer"}, "d1"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call("request_work", %{"instruction" => "peer", "team" => "code-review", "agent" => "style-reviewer"}, "rw"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "style-reviewer" -> [Fake.text("styled")]
      true -> [Fake.text("ok")]
    end
  end

  defp mediated_script(agent_id, depth, _ws, team, reason) do
    cond do
      reason == "cross_lineage" ->
        [Fake.tool_call("rewrite", %{"instruction" => "mediated style pass"}, "rw"), Fake.text("forwarded")]

      depth == 0 ->
        [
          Fake.tool_call("delegate", %{"instruction" => "review", "workspace" => "app", "team" => "code-review"}, "d0"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call("delegate", %{"instruction" => "scan", "agent" => "security-reviewer"}, "d1"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call("request_work", %{"instruction" => "original", "team" => "edit", "agent" => "editor"}, "rw"),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "editor" -> [Fake.text("edited")]
      true -> [Fake.text("ok")]
    end
  end

  defp tool_result(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("done", fn
      %{"role" => "tool", "content" => content} when is_binary(content) ->
        case Regex.run(~r/Result: ([^.]+)\./, content) do
          [_, value] -> value
          _ -> nil
        end

      _ -> nil
    end)
  end

  defp requested_events(core, correlation_id) do
    Enum.filter(EventCore.stream(core, 0, correlation_id: correlation_id), fn env ->
      env.type == "task.requested" and Map.has_key?(env.payload, "requested_by")
    end)
  end

  defp delegated_child(core, correlation_id, child_id) do
    Enum.find(
      EventCore.stream(core, 0, correlation_id: correlation_id, type: "task.delegated"),
      &(&1.payload["child_work_item_id"] == child_id)
    )
  end

  test "cross-team request_work routes through depth-0 LCA" do
    tmp = tmp_fixture!("complex-teams.toml")
    core = boot_complex(tmp, agents: SpikeAgents.resolver(script: &cross_team_script/5))
    {:ok, %{requested: requested}} = Runtime.request(core, "cross team review")
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.work_item_id == requested.work_item_id
    refute Enum.any?(EventCore.stream(core, 0, correlation_id: requested.correlation_id, type: "task.delegated"), fn env ->
      env.payload["team"] == "edit" and is_nil(env.payload["requested_by"]) and env.work_item_id != requested.work_item_id
    end)
  end

  test "with lane.toml overlay keeps cross-team routing" do
    tmp = tmp_fixture!("complex-teams.toml", "lane.toml")
    core = boot_complex(tmp, agents: SpikeAgents.resolver(script: &cross_team_script/5))
    {:ok, %{requested: requested}} = Runtime.request(core, "cross team review")
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.work_item_id == requested.work_item_id
  end

  test "sibling request_work routes through team leader LCA" do
    tmp = tmp_fixture!("complex-teams.toml")
    core = boot_complex(tmp, agents: SpikeAgents.resolver(script: &sibling_script/5))
    {:ok, %{requested: requested}} = Runtime.request(core, "sibling review")
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    lead_delegated = Enum.find(EventCore.stream(core, 0, correlation_id: requested.correlation_id, type: "task.delegated"), &(&1.payload["agent"] == "security-reviewer"))
    assert lead_delegated
    assert delegated.work_item_id == lead_delegated.work_item_id
    refute delegated.work_item_id == requested.work_item_id
  end

  test "mediated cross_lineage rewrites instruction" do
    overlay = "[session]\ncross_lineage = \"mediated\"\n"
    tmp = tmp_fixture!("complex-teams.toml")
    overlay_path = Path.join(tmp.dir, "mediated.toml")
    File.write!(overlay_path, File.read!(tmp.path) <> "\n" <> overlay)
    tmp = %{tmp | overlay_path: overlay_path, config: elem(Config.load(cwd: tmp.dir, config_file: overlay_path, env: %{}), 1)}
    core = boot_complex(tmp, agents: SpikeAgents.resolver(script: &mediated_script/5))
    {:ok, %{requested: requested}} = Runtime.request(core, "mediated review")
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.payload["instruction"] == "mediated style pass"
  end

  test "directory subtree vs session scope" do
    tmp = tmp_fixture!("complex-teams.toml")
    {:ok, config} = Config.load(cwd: tmp.dir, config_file: tmp.path, env: %{})
    base = %{workspaces: config.workspaces, teams: config.teams, agents: config.agents}
    session_ctx = Omunculus.Tool.Context.new(Omunculus.FS.Memory.new(%{}), Map.put(base, :directory_scope, "session"))
    subtree_ctx = Omunculus.Tool.Context.new(Omunculus.FS.Memory.new(%{}), Map.merge(base, %{directory_scope: "subtree", team: "code-review"}))
    {:ok, session_body, _} = Omunculus.Tools.Directory.call(%{}, session_ctx)
    {:ok, subtree_body, _} = Omunculus.Tools.Directory.call(%{}, subtree_ctx)
    session_result = Jason.decode!(session_body)
    subtree_result = Jason.decode!(subtree_body)
    assert session_result["scope"] == "session"
    assert subtree_result["scope"] == "subtree"
    assert length(session_result["teams"]) >= length(subtree_result["teams"])
    assert subtree_result["teams"] == ["code-review"]
  end

  test "TeamGate vetoes request_work to unknown team" do
    veto_script = fn agent_id, depth, _ws, team, reason ->
      cond do
        depth == 0 and reason != "arbitration" -> [Fake.tool_call("delegate", %{"instruction" => "x", "workspace" => "app", "team" => "code-review"}, "d0"), Fake.text("ok")]
        team == "code-review" and agent_id == "review-lead" -> [Fake.tool_call("delegate", %{"instruction" => "x", "agent" => "security-reviewer"}, "d1"), Fake.text("ok")]
        agent_id == "security-reviewer" -> [Fake.tool_call("request_work", %{"instruction" => "x", "team" => "ghost", "agent" => "nope"}, "rw"), Fake.text("ok")]
        true -> [Fake.text("ok")]
      end
    end
    tmp = tmp_fixture!("complex-teams.toml", "lane.toml")
    core = boot_complex(tmp, agents: SpikeAgents.resolver(script: veto_script))
    {:ok, %{requested: requested}} = Runtime.request(core, "veto test")
    rejection = Enum.find(EventCore.stream(core, 0, correlation_id: requested.correlation_id), fn env ->
      env.type == "delivery.rejected" and env.payload["interceptor"] == "team-gate"
    end)
    assert rejection
  end
end
