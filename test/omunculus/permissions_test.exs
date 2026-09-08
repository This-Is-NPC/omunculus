defmodule Omunculus.PermissionsTest do
  use ExUnit.Case, async: false

  alias Omunculus.Chat.Fake
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Events
  alias Omunculus.Harness
  alias Omunculus.Interceptors.ToolGate
  alias Omunculus.Matrix
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Agents

  @tool_gate %{
    name: "tool-gate",
    events: ["tool.call.requested"],
    module: ToolGate,
    options: %{}
  }

  @bands %{
    "granted" => ["counter"],
    "negotiable" => [],
    "human" => [],
    "forbidden" => []
  }

  test "temporary lineage grant ends when grant-root task completes" do
    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, projector} = Projector.start_link(core: core)

    seed_lineage!(core, projector, grandchild: true)

    child_started = run_started!(core, "run-child", "wi-child", "corr-temp")
    :ok = Projector.sync(projector)

    req_id = Events.request_id("wi-child", "edit")

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        causation_id: "evt-perm",
        correlation_id: "corr-temp",
        work_item_id: "wi-child",
        run_id: "run-child",
        payload: %{request_id: req_id, tool: "edit", reason: "patch"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        correlation_id: "corr-temp",
        work_item_id: "wi-child",
        payload: %{request_id: req_id, kind: "temporary", granter: "human:test"}
      )
    )

    grand_started = run_started!(core, "run-grand", "wi-grand", "corr-temp")
    assert deliver_tool!(core, grand_started, "run-grand", "wi-grand", "edit")

    EventCore.append!(
      core,
      Envelope.event("task.completed",
        correlation_id: "corr-temp",
        causation_id: child_started.event_id,
        work_item_id: "wi-child",
        payload: %{result: "done", depth: 1}
      )
    )

    :ok = Projector.sync(projector)

    refute deliver_tool!(core, grand_started, "run-grand", "wi-grand", "edit")
    refute Enum.any?(EventCore.stream(core, 0, type: "permission.revoked"))
  end

  test "policy.changed grants another task's open permission.requested" do
    tmp = perm_overlay!()
    {:ok, core} = EventCore.start_link(path: ":memory:")
    {:ok, projector} = Projector.start_link(core: core)

    req_a = Events.request_id("wi-a", "edit")
    req_b = Events.request_id("wi-b", "edit")

    seed_open_permission!(core, projector, "wi-a", req_a)
    seed_open_permission!(core, projector, "wi-b", req_b)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 0,
        agents: Agents.resolver(),
        config: runtime_config(tmp),
        run_opts: [delegation_timeout: 10_000]
      )

    File.write!(tmp.path, granted_perm_overlay())

    policy_changed =
      EventCore.append!(
        core,
        Envelope.event("policy.changed",
          correlation_id: "corr-policy",
          causation_id: "evt-policy",
          payload: %{}
        )
      )

    granted =
      Harness.await_log(core, fn env ->
        env.type == "permission.granted" and env.payload["request_id"] == req_a
      end)

    assert granted.payload["kind"] == "permanent"
    assert granted.payload["granter"] == "policy"
    assert granted.causation_id == policy_changed.event_id
  end

  test "policy reload emits a new policy.loaded after TOML grants edit" do
    tmp = perm_overlay!()
    {:ok, core} = EventCore.start_link(path: ":memory:")
    {:ok, _projector} = Projector.start_link(core: core)

    agents =
      Agents.resolver(
        script: fn _id, _depth, _, _ ->
          [Fake.tool_call("counter", %{}, "call_counter"), Fake.report("1")]
        end
      )

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 0,
        agents: agents,
        config: runtime_config(tmp),
        run_opts: [delegation_timeout: 10_000]
      )

    assert {:ok, _} = Runtime.request(core, "count", timeout: 10_000)

    first_hash =
      core
      |> EventCore.stream(0, type: "policy.loaded")
      |> List.last()
      |> Map.fetch!(:payload)
      |> Map.fetch!("hash")

    File.write!(tmp.path, granted_perm_overlay())

    assert {:ok, _} = Runtime.request(core, "count again", timeout: 10_000)

    loaded = EventCore.stream(core, 0, type: "policy.loaded")
    assert length(loaded) >= 2
    assert List.last(loaded).payload["hash"] != first_hash

    started =
      EventCore.stream(core, 0, type: "run.started")
      |> Enum.at(-1)

    assert "edit" in started.payload["tools"]["granted"]
  end

  test "complex.toml infra worker requests edit with human arbiter and no arbitration run" do
    assert_complex_permission(nil)
  end

  test "complex.toml with lane overlay still reaches human permission.requested" do
    assert_complex_permission("lane.toml")
  end

  defp assert_complex_permission(overlay) do
    agents = complex_permission_agents()

    %{core: core, runtime: runtime, tmp: tmp} = boot_complex(overlay, agents)

    task = Task.async(fn -> Runtime.request(core, "infra edit permission", timeout: 2_000) end)
    Process.sleep(500)

    requested =
      Harness.await_log(core, fn env ->
        env.type == "permission.requested" and env.payload["tool"] == "edit"
      end)

    assert requested.payload["arbiter"] == "human"

    refute Enum.any?(
             EventCore.stream(core, 0, type: "run.started"),
             &(&1.payload["reason"] == "arbitration")
           )

    if overlay do
      assert "tool-gate" in Enum.map(tmp.config.interceptors, & &1.name)
    end

    Task.shutdown(task, :brutal_kill)
    GenServer.stop(runtime)
  end

  defp complex_permission_agents do
    Agents.resolver(
      script: fn _agent_id, depth, _workspace, _team ->
        if depth < 2 do
          [
            Fake.tool_call(
              "delegate",
              %{
                "comment" => "Preserve this task context and review the result",
                "work_item" => %{"instruction" => "work infra edit"},
                "workspace" => "infra"
              },
              "call_del_#{depth}"
            ),
            Fake.report("done")
          ]
        else
          [
            Fake.tool_call(
              "request_permission",
              %{
                "comment" => "Preserve this task context and review the result",
                "tool" => "edit",
                "reason" => "patch infra"
              },
              "call_rp"
            ),
            Fake.report("ok")
          ]
        end
      end
    )
  end

  defp boot_complex(overlay, agents) do
    tmp = Harness.tmp_fixture("complex.toml", overlay)
    on_exit(fn -> File.rm_rf!(tmp.dir) end)

    interceptors = if overlay, do: Matrix.interceptors_from_config(tmp.config), else: []

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: interceptors)
    {:ok, projector} = Projector.start_link(core: core)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 2,
        agents: agents,
        config: [
          cwd: tmp.dir,
          config_file: tmp.overlay_path || tmp.path,
          env: %{},
          profile: "coding"
        ],
        run_opts: [delegation_timeout: 10_000]
      )

    %{core: core, projector: projector, runtime: runtime, tmp: tmp}
  end

  defp perm_overlay! do
    dir = Path.join(System.tmp_dir!(), "omunculus-perms-#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p!(dir)
    path = Path.join(dir, "omunculus.toml")
    File.write!(path, human_edit_overlay())
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: path}
  end

  defp runtime_config(tmp) do
    [cwd: tmp.dir, config_file: tmp.path, env: %{}, profile: "perm"]
  end

  defp human_edit_overlay do
    """
    [profiles.perm]
    mode = "deny"
    granted = ["counter"]
    human = ["edit"]

    [policy.depth.0]
    mode = "deny"
    granted = ["counter"]
    human = ["edit"]

    [workspaces.app]
    roots = ["."]
    mode = "allow"

    [agents.worker]
    prompt = "worker"
    """
  end

  defp granted_perm_overlay do
    """
    [profiles.perm]
    mode = "deny"
    granted = ["counter", "edit"]
    human = []

    [policy.depth.0]
    mode = "deny"
    granted = ["counter", "edit"]
    human = []

    [workspaces.app]
    roots = ["."]
    mode = "allow"
    granted = ["edit"]

    [agents.worker]
    prompt = "worker"
    """
  end

  defp seed_open_permission!(core, projector, work_item_id, request_id, workspace \\ "app") do
    cmd =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: work_item_id,
          workspace_id: workspace,
          payload: %{instruction: "need edit", workspace: workspace}
        )
      )

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          work_item_id: work_item_id,
          run_id: "run-#{work_item_id}",
          correlation_id: cmd.correlation_id,
          causation_id: cmd.event_id,
          payload: %{
            depth: 0,
            attempt: 1,
            agent_id: "worker",
            agent_kind: "worker",
            reason: "initial",
            tools: %{
              "granted" => [],
              "negotiable" => [],
              "human" => ["edit"],
              "forbidden" => []
            }
          }
        )
      )

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        work_item_id: work_item_id,
        run_id: "run-#{work_item_id}",
        workspace_id: workspace,
        correlation_id: cmd.correlation_id,
        causation_id: started.event_id,
        payload: %{
          request_id: request_id,
          tool: "edit",
          arbiter: "human",
          workspace: workspace,
          reason: "need edit"
        }
      )
    )

    EventCore.append!(
      core,
      Envelope.event("run.completed",
        work_item_id: work_item_id,
        run_id: "run-#{work_item_id}",
        correlation_id: cmd.correlation_id,
        causation_id: started.event_id,
        payload: %{outcome: "waiting", awaiting: [request_id], checkpoint: %{}}
      )
    )

    :ok = Projector.sync(projector)
  end

  defp seed_lineage!(core, projector, opts) do
    EventCore.append!(
      core,
      Envelope.command("task.requested", work_item_id: "wi-root", payload: %{instruction: "root"})
    )

    EventCore.append!(
      core,
      Envelope.event("task.delegated",
        causation_id: "evt-parent",
        work_item_id: "wi-root",
        payload: %{
          work_item: %{"instruction" => "child"},
          comment: "Delegated task context",
          child_work_item_id: "wi-child",
          to_depth: 1,
          parent_run_id: "run-root",
          originating_run_id: "run-root"
        }
      )
    )

    if Keyword.get(opts, :grandchild) do
      EventCore.append!(
        core,
        Envelope.event("task.delegated",
          causation_id: "evt-parent",
          work_item_id: "wi-child",
          payload: %{
            work_item: %{"instruction" => "grandchild"},
            comment: "Delegated task context",
            child_work_item_id: "wi-grand",
            to_depth: 2,
            parent_run_id: "run-child",
            originating_run_id: "run-root"
          }
        )
      )
    end

    :ok = Projector.sync(projector)
  end

  defp run_started!(core, run_id, work_item_id, corr) do
    EventCore.append!(
      core,
      Envelope.event("run.started",
        causation_id: "evt-run",
        correlation_id: corr,
        work_item_id: work_item_id,
        run_id: run_id,
        payload: %{
          tools: @bands,
          attempt: 1,
          depth: 1,
          agent_id: "w",
          agent_kind: "worker",
          reason: "initial"
        }
      )
    )
  end

  defp deliver_tool!(core, started, run_id, work_item_id, tool) do
    :ok = EventCore.subscribe(core)

    try do
      {:ok, env} =
        EventCore.append(
          core,
          Envelope.event("tool.call.requested",
            correlation_id: started.correlation_id,
            causation_id: started.event_id,
            work_item_id: work_item_id,
            run_id: run_id,
            payload: %{tool: tool, round: 1}
          )
        )

      receive do
        {:event_core, %{event_id: id, type: "tool.call.requested"}} -> id == env.event_id
      after
        100 -> false
      end
    after
      EventCore.unsubscribe(core)
    end
  end
end
