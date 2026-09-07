defmodule Omunculus.TeamsRequestWorkTest do
  use ExUnit.Case, async: true

  alias Omunculus.Chat.Fake
  alias Omunculus.Config
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Harness
  alias Omunculus.Matrix
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Agents

  @delegation_overlay """
  [profiles.delegating]
  mode = "allow"
  deny = ["counter"]

  [policy.depth.1]
  mode = "allow"
  negotiable = []
  directory = "session"

  [policy.depth.2]
  mode = "allow"
  deny = ["delegate"]
  negotiable = []
  directory = "session"
  """

  defp request(core, instruction, opts) do
    result = Runtime.request(core, instruction, opts)

    assert match?({:ok, _}, result),
           inspect(
             EventCore.stream(core, 0)
             |> Enum.reject(&(&1.type in ["policy.loaded", "model.call.completed"]))
             |> Enum.take(35)
             |> Enum.map(
               &{&1.type, &1.work_item_id,
                Map.take(&1.payload, [
                  "reason",
                  "detail",
                  "agent_id",
                  "team",
                  "instruction",
                  "outcome",
                  "awaiting",
                  "result",
                  "to_depth"
                ])}
             ),
             limit: :infinity,
             pretty: true
           )

    {:ok, %{requested: requested}} = result

    Matrix.contract_invariants!(%{
      core: core,
      projector: Process.get({:projector, core}),
      correlation_id: requested.correlation_id
    })

    result
  end

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
          File.write!(path, @delegation_overlay)
          path

        lane_path ->
          File.write!(lane_path, File.read!(lane_path) <> "\n" <> @delegation_overlay)
          lane_path
      end

    {:ok, config} = Config.load(cwd: tmp.dir, config_file: config_file, env: %{})
    assert Map.has_key?(config.presets, "delegating")
    tmp = %{tmp | config: config, overlay_path: config_file}

    interceptors =
      Keyword.get_lazy(opts, :interceptors, fn ->
        case tmp.overlay_path do
          nil -> []
          _ -> tmp.config |> Matrix.interceptors_from_config() |> enrich_lane_options(tmp.config)
        end
      end)

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)
    Process.put({:projector, core}, projector)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: Keyword.get(opts, :max_depth, 2),
        agents: Keyword.get(opts, :agents, Agents.resolver()),
        config: [cwd: tmp.dir, config_file: config_file, env: %{}, profile: "delegating"],
        run_opts: [delegation_timeout: 15_000, fs: Omunculus.FS.Memory.new(%{})]
      )

    Process.put({:runtime, core}, runtime)

    Process.put({:runtime_config, core},
      cwd: tmp.dir,
      config_file: config_file,
      env: %{},
      profile: "delegating"
    )

    core
  end

  defp cross_team_script(agent_id, depth, _ws, team, reason) do
    cond do
      reason == "continuation" ->
        [fn msgs -> Fake.text(tool_result(msgs)) end]

      depth == 0 and reason != "arbitration" ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "review", "workspace" => "app", "team" => "code-review"},
            "d0"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "scan", "agent" => "security-reviewer"},
            "d1"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call(
            "request_work",
            %{"instruction" => "style pass", "team" => "edit", "agent" => "editor"},
            "rw"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "editor" ->
        [Fake.text("edited")]

      true ->
        [Fake.text("ok")]
    end
  end

  defp sibling_script(agent_id, depth, _ws, team, reason) do
    cond do
      reason == "continuation" ->
        [fn msgs -> Fake.text(tool_result(msgs)) end]

      depth == 0 and reason != "arbitration" ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "review", "workspace" => "app", "team" => "code-review"},
            "d0"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "scan", "agent" => "security-reviewer"},
            "d1"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call(
            "request_work",
            %{"instruction" => "peer", "team" => "code-review", "agent" => "style-reviewer"},
            "rw"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "style-reviewer" ->
        [Fake.text("styled")]

      true ->
        [Fake.text("ok")]
    end
  end

  defp mediated_script(agent_id, depth, _ws, team, reason) do
    cond do
      reason == "continuation" ->
        [fn msgs -> Fake.text(tool_result(msgs)) end]

      reason == "arbitration" ->
        [
          Fake.tool_call("rewrite", %{"instruction" => "mediated style pass"}, "rw"),
          Fake.text("forwarded")
        ]

      depth == 0 ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "review", "workspace" => "app", "team" => "code-review"},
            "d0"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      team == "code-review" and agent_id == "review-lead" ->
        [
          Fake.tool_call(
            "delegate",
            %{"instruction" => "scan", "agent" => "security-reviewer"},
            "d1"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "security-reviewer" ->
        [
          Fake.tool_call(
            "request_work",
            %{"instruction" => "original", "team" => "edit", "agent" => "editor"},
            "rw"
          ),
          fn msgs -> Fake.text(tool_result(msgs)) end
        ]

      agent_id == "editor" ->
        [Fake.text("edited")]

      true ->
        [Fake.text("ok")]
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

      _ ->
        nil
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
    core = boot_complex(tmp, agents: Agents.resolver(script: &cross_team_script/5))
    {:ok, %{requested: requested}} = request(core, "cross team review", timeout: 3_000)
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.work_item_id == requested.work_item_id

    refute Enum.any?(
             EventCore.stream(core, 0,
               correlation_id: requested.correlation_id,
               type: "task.delegated"
             ),
             fn env ->
               env.payload["team"] == "edit" and is_nil(env.payload["requested_by"]) and
                 env.work_item_id != requested.work_item_id
             end
           )
  end

  test "with lane.toml overlay keeps cross-team routing" do
    tmp = tmp_fixture!("complex-teams.toml", "lane.toml")
    core = boot_complex(tmp, agents: Agents.resolver(script: &cross_team_script/5))
    {:ok, %{requested: requested}} = request(core, "cross team review", timeout: 3_000)
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.work_item_id == requested.work_item_id
  end

  test "sibling request_work routes through team leader LCA" do
    tmp = tmp_fixture!("complex-teams.toml")
    core = boot_complex(tmp, agents: Agents.resolver(script: &sibling_script/5))
    {:ok, %{requested: requested}} = request(core, "sibling review", timeout: 3_000)
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])

    lead_delegated =
      Enum.find(
        EventCore.stream(core, 0,
          correlation_id: requested.correlation_id,
          type: "task.delegated"
        ),
        &(&1.payload["agent"] == "security-reviewer")
      )

    assert lead_delegated
    assert delegated.work_item_id == lead_delegated.work_item_id
    refute delegated.work_item_id == requested.work_item_id
  end

  test "mediated cross_lineage rewrites instruction" do
    overlay = "[session]\ncross_lineage = \"mediated\"\n"
    tmp = tmp_fixture!("complex-teams.toml")
    overlay_path = Path.join(tmp.dir, "mediated.toml")
    File.write!(overlay_path, overlay)

    tmp = %{
      tmp
      | overlay_path: overlay_path,
        config: elem(Config.load(cwd: tmp.dir, config_file: overlay_path, env: %{}), 1)
    }

    core = boot_complex(tmp, agents: Agents.resolver(script: &mediated_script/5))
    {:ok, %{requested: requested}} = request(core, "mediated review", timeout: 3_000)
    [rw | _] = requested_events(core, requested.correlation_id)
    delegated = delegated_child(core, requested.correlation_id, rw.payload["child_work_item_id"])
    assert delegated.payload["instruction"] == "mediated style pass"
  end

  test "mediated denial resumes the correct requester and preserves the leader checkpoint" do
    tmp = tmp_fixture!("complex-teams.toml")
    overlay = Path.join(tmp.dir, "denial.toml")
    File.write!(overlay, "[session]\ncross_lineage = \"mediated\"\n")

    script = fn agent, depth, ws, team, reason ->
      if reason == "arbitration" do
        [
          Fake.tool_call("deny", %{"reason" => "outside current task"}, "deny"),
          Fake.text("denied")
        ]
      else
        cross_team_script(agent, depth, ws, team, reason)
      end
    end

    core = boot_complex(%{tmp | overlay_path: overlay}, agents: Agents.resolver(script: script))
    {:ok, %{requested: root}} = request(core, "review", timeout: 3_000)
    [req] = requested_events(core, root.correlation_id)

    assert [] ==
             EventCore.stream(core, 0, type: "task.delegated")
             |> Enum.filter(&(&1.payload["requested_by"] == req.payload["requested_by"]))

    continuation =
      EventCore.stream(core, 0, work_item_id: req.work_item_id, type: "run.started")
      |> List.last()

    assert continuation.payload["reason"] == "continuation"
    assert inspect(continuation.payload["checkpoint"]) =~ "outside current task"
  end

  test "completed response resumes its requester after runtime restart" do
    tmp = tmp_fixture!("complex-teams.toml")
    parent = self()

    script = fn agent, depth, ws, team, reason ->
      if agent == "style-reviewer" do
        [
          fn _ ->
            send(parent, {:target_started, self()})

            receive do
              :finish -> Fake.text("styled")
            end
          end
        ]
      else
        sibling_script(agent, depth, ws, team, reason)
      end
    end

    core = boot_complex(tmp, agents: Agents.resolver(script: script))
    task = Task.async(fn -> Runtime.request(core, "review", timeout: 5_000) end)
    assert_receive {:target_started, fake}, 2_000

    req =
      Harness.await_log(
        core,
        &(&1.type == "task.requested" and Map.has_key?(&1.payload, "requested_by"))
      )

    Harness.await_log(
      core,
      &(&1.type == "run.completed" and &1.work_item_id == req.work_item_id and
          &1.payload["outcome"] == "waiting")
    )

    projector = Process.get({:projector, core})
    Projector.sync(projector)
    snapshot = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert snapshot == Projector.snapshot(core)
    runtime = Process.get({:runtime, core})
    :sys.suspend(runtime)
    send(fake, :finish)

    Harness.await_log(
      core,
      &(&1.type == "task.completed" and &1.work_item_id == req.payload["child_work_item_id"])
    )

    :sys.terminate(runtime, :normal)

    {:ok, _} =
      Runtime.start_link(
        core: core,
        max_depth: 2,
        agents: Agents.resolver(script: script),
        config: Process.get({:runtime_config, core}),
        run_opts: [fs: Omunculus.FS.Memory.new(%{})]
      )

    assert {:ok, _} = Task.await(task, 5_000)
  end

  test "directory subtree vs session scope" do
    tmp = tmp_fixture!("complex-teams.toml")
    {:ok, config} = Config.load(cwd: tmp.dir, config_file: tmp.path, env: %{})
    base = %{workspaces: config.workspaces, teams: config.teams, agents: config.agents}

    session_ctx =
      Omunculus.Tool.Context.new(
        Omunculus.FS.Memory.new(%{}),
        Map.put(base, :directory_scope, "session")
      )

    subtree_ctx =
      Omunculus.Tool.Context.new(
        Omunculus.FS.Memory.new(%{}),
        Map.merge(base, %{directory_scope: "subtree", team: "code-review"})
      )

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
        reason == "continuation" ->
          [Fake.text("ok")]

        depth == 0 and reason != "arbitration" ->
          [
            Fake.tool_call(
              "delegate",
              %{"instruction" => "x", "workspace" => "app", "team" => "code-review"},
              "d0"
            ),
            Fake.text("ok")
          ]

        team == "code-review" and agent_id == "review-lead" ->
          [
            Fake.tool_call(
              "delegate",
              %{"instruction" => "x", "agent" => "security-reviewer"},
              "d1"
            ),
            Fake.text("ok")
          ]

        agent_id == "security-reviewer" ->
          [
            Fake.tool_call(
              "request_work",
              %{"instruction" => "x", "team" => "ghost", "agent" => "nope"},
              "rw"
            ),
            Fake.text("ok")
          ]

        true ->
          [Fake.text("ok")]
      end
    end

    tmp = tmp_fixture!("complex-teams.toml", "lane.toml")
    core = boot_complex(tmp, agents: Agents.resolver(script: veto_script))
    {:ok, %{requested: requested}} = request(core, "veto test", timeout: 3_000)

    rejection =
      Enum.find(EventCore.stream(core, 0, correlation_id: requested.correlation_id), fn env ->
        env.type == "delivery.rejected" and env.payload["interceptor"] == "team-gate"
      end)

    assert rejection
  end
end
