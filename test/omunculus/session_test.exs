defmodule Omunculus.SessionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Omunculus.{Automations, Harness}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Agents

  @attached ~w(app infra)

  @node_scope_overlay """
  [profiles.full]
  mode = "allow"

  [teams.count]
  lead = "counter"
  members = []
  profile = "count"
  scope = "node"

  [teams.edit]
  lead = "editor"
  members = []
  profile = "coding"
  scope = "node"
  """

  defp boot_complex(opts \\ []) do
    base = Keyword.get(opts, :base, "complex.toml")
    tmp = Harness.tmp_fixture(base, Keyword.get(opts, :overlay, "lane.toml"))
    tmp = maybe_append_overlay(tmp, Keyword.get(opts, :append_overlay))
    interceptors = interceptors_for(tmp.config, Keyword.get(opts, :extras, false))

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)

    session_id =
      Keyword.get(
        opts,
        :session_id,
        "sess-complex-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    seed_session!(core, projector, session_id, @attached)

    runtime_config = [
      cwd: tmp.dir,
      config_file: tmp.overlay_path || tmp.path,
      env: %{},
      profile: Keyword.get(opts, :profile, "count")
    ]

    agents = Keyword.get(opts, :agents, Agents.resolver())

    runtime =
      if Keyword.get(opts, :runtime, true) do
        {:ok, pid} =
          Runtime.start_link(
            core: core,
            max_depth: Keyword.get(opts, :max_depth, 2),
            agents: agents,
            config: runtime_config,
            run_opts: [delegation_timeout: 10_000]
          )

        pid
      end

    %{
      core: core,
      projector: projector,
      runtime: runtime,
      session_id: session_id,
      tmp: tmp,
      runtime_config: runtime_config,
      agents: agents
    }
  end

  defp maybe_append_overlay(tmp, nil), do: tmp

  defp maybe_append_overlay(tmp, overlay) when is_binary(overlay) do
    config_file = tmp.overlay_path || tmp.path
    File.write!(config_file, File.read!(config_file) <> "\n" <> overlay)
    {:ok, config} = Omunculus.Config.load(cwd: tmp.dir, config_file: config_file, env: %{})
    %{tmp | config: config, overlay_path: config_file}
  end

  defp interceptors_for(config, extras?) do
    lane = Omunculus.Matrix.interceptors_from_config(config)
    if extras?, do: lane ++ extra_interceptors(), else: lane
  end

  defp extra_interceptors do
    extras = [
      %{
        name: "infra-readonly",
        events: ["tool.call.requested"],
        workspaces: ["infra"],
        module: Omunculus.Interceptors.ToolGate,
        options: %{}
      }
    ]

    if Code.ensure_loaded?(Omunculus.Interceptors.WorkspaceGate) do
      extras ++
        [
          %{
            name: "workspace-gate",
            events: ["task.requested", "task.delegated"],
            module: Omunculus.Interceptors.WorkspaceGate,
            options: %{attached: @attached}
          }
        ]
    else
      extras
    end
  end

  defp seed_session!(core, projector, session_id, workspace_ids) do
    EventCore.append!(
      core,
      Envelope.command("session.created",
        session_id: session_id,
        payload: %{"session_id" => session_id}
      )
    )

    for ws <- workspace_ids do
      EventCore.append!(
        core,
        Envelope.command("workspace.attached",
          session_id: session_id,
          payload: %{"workspace_id" => ws}
        )
      )
    end

    :ok = Projector.sync(projector)
  end

  defp node_id_depth0(session_id) do
    hash_node_id([session_id, 0])
  end

  defp node_id_depth1(session_id, workspace_id, team \\ nil) do
    parts =
      if is_binary(team) and team != "" do
        [session_id, workspace_id, team, 1]
      else
        [session_id, workspace_id, 1]
      end

    hash_node_id(parts)
  end

  defp hash_node_id(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("node_" <> String.slice(&1, 0, 16)))
  end

  test "workspace.attached does not start a Run" do
    %{core: core, runtime: runtime, session_id: session_id, projector: projector} = boot_complex()

    EventCore.append!(
      core,
      Envelope.command("workspace.attached",
        session_id: session_id,
        payload: %{"workspace_id" => "infra"}
      )
    )

    :ok = Projector.sync(projector)
    assert map_size(Runtime.runs(runtime)) == 0
  end

  test "depth-1 node_id is stable across two Runs in the same workspace" do
    %{core: core, session_id: session_id} = boot_complex()

    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)
    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)

    node_ids =
      EventCore.stream(core, 0, type: "run.started")
      |> Enum.filter(&(&1.payload["depth"] == 1))
      |> Enum.map(& &1.payload["node_id"])

    assert node_ids != []
    expected = node_id_depth1(session_id, "app")
    assert Enum.all?(node_ids, &(&1 == expected))
  end

  test "node-scoped teams get distinct depth-1 node_ids and reuse per team" do
    %{core: core, session_id: session_id} =
      boot_complex(
        base: "complex-teams.toml",
        extras: true,
        max_depth: 1,
        profile: "full",
        append_overlay: @node_scope_overlay
      )

    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)
    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)
    {:ok, _} = Runtime.request(core, "escrever README", session_id: session_id)

    by_team =
      EventCore.stream(core, 0, type: "run.started")
      |> Enum.filter(&(&1.payload["depth"] == 1))
      |> Enum.group_by(& &1.payload["team"], & &1.payload["node_id"])

    count_ids = by_team["count"] || []
    edit_ids = by_team["edit"] || []

    assert length(count_ids) >= 2
    assert edit_ids != []

    expected_count = node_id_depth1(session_id, "app", "count")
    expected_edit = node_id_depth1(session_id, "app", "edit")

    assert Enum.all?(count_ids, &(&1 == expected_count))
    assert Enum.all?(edit_ids, &(&1 == expected_edit))
    refute expected_count == expected_edit
  end

  test "workspace.detached fails an open run with reason detached" do
    alias Omunculus.Chat.Fake

    blocking = fn ctx ->
      case ctx.depth do
        1 ->
          %{
            Agents.resolve(ctx, %{})
            | chat:
                Fake.new([
                  fn _ ->
                    :timer.sleep(30_000)
                    Fake.text("late")
                  end
                ])
          }

        _ ->
          %{
            Agents.resolve(ctx, %{})
            | chat:
                Fake.new([
                  Fake.tool_call(
                    "delegate",
                    %{"instruction" => "block", "workspace" => "app"},
                    "call_delegate"
                  )
                ])
          }
      end
    end

    %{core: core, session_id: session_id, projector: projector} = boot_complex(agents: blocking)

    task =
      Task.async(fn -> Runtime.request(core, "block", session_id: session_id, timeout: 60_000) end)

    _started =
      Harness.await_log(core, fn env ->
        env.type == "run.started" and env.payload["depth"] == 1
      end)

    EventCore.append!(
      core,
      Envelope.command("workspace.detached",
        session_id: session_id,
        payload: %{"workspace_id" => "app"}
      )
    )

    failed =
      Harness.await_log(core, fn env ->
        env.type == "run.failed" and env.payload["reason"] == "detached"
      end)

    assert failed.payload["reason"] == "detached"
    Task.shutdown(task, :brutal_kill)
    :ok = Projector.sync(projector)
  end

  test "task.commented is visible on the next depth-0 request" do
    comment = "remember the infra boundary"

    %{
      core: core,
      session_id: session_id,
      runtime_config: runtime_config,
      agents: agents,
      projector: projector
    } =
      boot_complex(runtime: false)

    EventCore.append!(
      core,
      Envelope.command("task.commented",
        session_id: session_id,
        work_item_id: "wi-note",
        payload: %{"body" => comment, "kind" => "note"}
      )
    )

    :ok = Projector.sync(projector)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 2,
        agents: agents,
        config: runtime_config,
        run_opts: [delegation_timeout: 10_000]
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)

    assert {:ok, %{result: "3", requested: requested}} =
             Runtime.request(core, "conte até 3", session_id: session_id)

    started =
      EventCore.stream(core, 0, correlation_id: requested.correlation_id, type: "run.started")
      |> Enum.find(&(&1.payload["depth"] == 0))

    messages = get_in(started.payload, ["checkpoint", "messages"]) || []

    assert Enum.any?(messages, fn
             %{"role" => "user", "content" => content} when is_binary(content) ->
               String.contains?(content, comment)

             _ ->
               false
           end)
  end

  test "attached app and infra workspaces run a depth-2 count task" do
    %{core: core, session_id: session_id} = boot_complex(extras: true)

    assert {:ok, %{result: "3"}} =
             Runtime.request(core, "conte até 3", session_id: session_id)
  end

  test "two workspaces attached project SESSION_WORKSPACES with attached=1" do
    %{core: core} = boot_complex(runtime: false)

    assert [["app", 1], ["infra", 1]] =
             EventCore.query(
               core,
               "SELECT workspace_id, attached FROM SESSION_WORKSPACES ORDER BY workspace_id"
             )
  end

  test "app-routed count task carries session_id and workspace_id on envelopes" do
    %{core: core, session_id: session_id} = boot_complex()

    {:ok, %{result: result, requested: requested}} =
      Runtime.request(core, "conte até 3", session_id: session_id)

    assert result == "3"
    events = EventCore.stream(core, 0, correlation_id: requested.correlation_id)

    chain =
      Enum.filter(
        events,
        &(&1.type in ~w(task.requested task.delegated run.started run.completed task.completed tool.call.requested tool.call.completed))
      )

    assert Enum.all?(chain, &(&1.session_id == session_id))

    depth0 =
      Enum.filter(events, fn env ->
        env.type == "run.started" and env.payload["depth"] == 0 and
          env.payload["reason"] == "initial"
      end)

    assert depth0 != []
    assert Enum.all?(depth0, &is_nil(&1.workspace_id))

    depth_ge_1 =
      Enum.filter(events, fn env ->
        (env.type == "run.started" and env.payload["depth"] >= 1) or
          (env.type == "task.completed" and env.payload["depth"] >= 1)
      end)

    assert depth_ge_1 != []
    assert Enum.all?(depth_ge_1, &(&1.workspace_id == "app"))
  end

  test "depth-0 node_id is stable across two root requests" do
    %{core: core, session_id: session_id} = boot_complex()
    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)
    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)

    node_ids =
      EventCore.stream(core, 0, type: "run.started")
      |> Enum.filter(&(&1.payload["depth"] == 0))
      |> Enum.map(& &1.payload["node_id"])

    assert length(node_ids) >= 2
    expected = node_id_depth0(session_id)
    assert Enum.all?(node_ids, &(&1 == expected))
  end

  test "infra workspace blocks write at policy, lane, and completion layers" do
    %{core: core, tmp: tmp} = boot_complex(extras: true, runtime: false)

    {:ok, config} =
      Omunculus.Config.load(
        cwd: tmp.dir,
        config_file: tmp.overlay_path || tmp.path,
        env: %{}
      )

    table = Omunculus.Policy.table(config)
    {:ok, bands} = Omunculus.Policy.line(table, "count", "2", "infra")

    run_id = "run-infra"
    corr = "corr-infra"

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          correlation_id: corr,
          causation_id: "cmd-infra",
          work_item_id: "wi-infra",
          run_id: run_id,
          workspace_id: "infra",
          payload: %{
            "attempt" => 1,
            "depth" => 2,
            "agent_id" => "worker",
            "agent_kind" => "worker",
            "reason" => "initial",
            "tools" => bands
          }
        )
      )

    refute "write" in started.payload["tools"]["granted"]
    refute "edit" in started.payload["tools"]["granted"]

    write_requested =
      EventCore.append!(
        core,
        Envelope.event("tool.call.requested",
          correlation_id: corr,
          causation_id: started.event_id,
          work_item_id: "wi-infra",
          run_id: run_id,
          workspace_id: "infra",
          payload: %{"tool" => "write", "round" => 1, "args" => %{"path" => "x.txt"}}
        )
      )

    rejection =
      EventCore.stream(core, 0, correlation_id: corr)
      |> Enum.find(&(&1.type == "delivery.rejected"))

    assert rejection.payload["rejected_event_id"] == write_requested.event_id
    assert rejection.payload["interceptor"] in ["tool-gate", "infra-readonly"]

    refute Enum.any?(EventCore.stream(core, 0, correlation_id: corr), fn env ->
             env.type == "tool.call.completed" and env.payload["tool"] == "write" and
               env.payload["outcome"] == "completed"
           end)
  end

  test "task.completed automation appends to a tmp log" do
    %{core: core, session_id: session_id, runtime_config: runtime_config, agents: agents} =
      boot_complex(runtime: false)

    out =
      Path.join(
        System.tmp_dir!(),
        "omunculus-session-auto-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}.log"
      )

    automations = [
      %{
        name: "log-completed",
        events: ["task.completed"],
        run: ~s(printf '%s\n' "$OMUNCULUS_EVENT_ID" >> "#{out}")
      }
    ]

    {:ok, auto} = Automations.start_link(core: core, automations: automations)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 2,
        agents: agents,
        config: runtime_config,
        run_opts: [delegation_timeout: 10_000]
      )

    on_exit(fn ->
      if Process.alive?(runtime), do: GenServer.stop(runtime)
      if Process.alive?(auto), do: GenServer.stop(auto)
      File.rm(out)
    end)

    {:ok, _} = Runtime.request(core, "conte até 3", session_id: session_id)
    :ok = Automations.sync(auto)
    assert out |> File.read!() |> String.trim() != ""
  end

  test "WorkspaceGate rejects delegation to a ghost workspace" do
    %{core: core, session_id: session_id} = boot_complex(runtime: false, extras: true)
    assert Code.ensure_loaded?(Omunculus.Interceptors.WorkspaceGate)

    delegated =
      EventCore.append!(
        core,
        Envelope.event("task.delegated",
          session_id: session_id,
          correlation_id: "corr-ghost",
          causation_id: "evt-parent",
          work_item_id: "wi-parent",
          run_id: "run-parent",
          payload: %{
            "instruction" => "noop",
            "child_work_item_id" => "wi-child",
            "to_depth" => 1,
            "parent_run_id" => "run-parent",
            "originating_run_id" => "run-parent",
            "workspace" => "ghost"
          }
        )
      )

    rejection =
      EventCore.stream(core, 0, correlation_id: "corr-ghost")
      |> Enum.find(&(&1.type == "delivery.rejected"))

    assert rejection.payload["interceptor"] == "workspace-gate"
    assert rejection.payload["rejected_event_id"] == delegated.event_id
  end

  describe "pending_continuations rebuild" do
    test "Runtime.init does not crash when no work items are waiting" do
      %{core: core, runtime_config: runtime_config, agents: agents} = boot_complex(runtime: false)

      assert {:ok, runtime} =
               Runtime.start_link(
                 core: core,
                 max_depth: 2,
                 agents: agents,
                 config: runtime_config,
                 run_opts: [delegation_timeout: 10_000]
               )

      assert Process.alive?(runtime)
      GenServer.stop(runtime)
    end

    test "a new Runtime continues a waiting parent after a child completes" do
      %{core: core, session_id: session_id, runtime_config: runtime_config, agents: agents} =
        boot_complex(runtime: false)

      parent_wi = "wi-parent"
      child_wi = "wi-child"
      corr = "corr-rebuild"
      run_parent = "run-parent"
      run_child = "run-child"

      requested =
        EventCore.append!(
          core,
          Envelope.command("task.requested",
            session_id: session_id,
            correlation_id: corr,
            work_item_id: parent_wi,
            payload: %{"instruction" => "parent"}
          )
        )

      started_parent =
        EventCore.append!(
          core,
          Envelope.event("run.started",
            session_id: session_id,
            correlation_id: corr,
            causation_id: requested.event_id,
            work_item_id: parent_wi,
            run_id: run_parent,
            payload: %{
              "attempt" => 1,
              "depth" => 0,
              "agent_id" => "concierge",
              "agent_kind" => "concierge",
              "reason" => "initial",
              "tools" => %{
                "granted" => ["delegate"],
                "negotiable" => [],
                "human" => [],
                "forbidden" => []
              }
            }
          )
        )

      delegated =
        EventCore.append!(
          core,
          Envelope.event("task.delegated",
            session_id: session_id,
            correlation_id: corr,
            causation_id: started_parent.event_id,
            work_item_id: parent_wi,
            run_id: run_parent,
            workspace_id: "app",
            payload: %{
              "instruction" => "conte até 3",
              "child_work_item_id" => child_wi,
              "to_depth" => 1,
              "parent_run_id" => run_parent,
              "originating_run_id" => run_parent,
              "workspace" => "app"
            }
          )
        )

      EventCore.append!(
        core,
        Envelope.event("run.completed",
          session_id: session_id,
          correlation_id: corr,
          causation_id: delegated.event_id,
          work_item_id: parent_wi,
          run_id: run_parent,
          payload: %{
            "outcome" => "waiting",
            "awaiting" => [child_wi],
            "checkpoint" => %{
              "messages" => [],
              "awaiting" => [child_wi],
              "pending" => %{child_wi => "call_delegate"}
            }
          }
        )
      )

      EventCore.append!(
        core,
        Envelope.event("task.completed",
          session_id: session_id,
          correlation_id: corr,
          causation_id: delegated.event_id,
          work_item_id: child_wi,
          run_id: run_child,
          workspace_id: "app",
          payload: %{"result" => "3", "depth" => 2}
        )
      )

      {:ok, projector} = Projector.start_link(core: core)
      :ok = Projector.sync(projector)

      assert {:ok, _runtime} =
               Runtime.start_link(
                 core: core,
                 max_depth: 2,
                 agents: agents,
                 config: runtime_config,
                 run_opts: [delegation_timeout: 10_000]
               )

      continuation =
        Harness.await_log(core, fn env ->
          env.type == "run.started" and env.work_item_id == parent_wi and
            env.payload["reason"] == "continuation"
        end)

      assert continuation.payload["reason"] == "continuation"
    end
  end
end
