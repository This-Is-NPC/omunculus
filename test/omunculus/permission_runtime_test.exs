defmodule Omunculus.PermissionRuntimeTest do
  use ExUnit.Case, async: false

  alias Omunculus.Chat.Fake
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Harness
  alias Omunculus.Interceptors.ToolGate
  alias Omunculus.Runtime
  alias Omunculus.Runtime.Agents
  alias Omunculus.Runtime.Permission, as: RuntimePermission

  @tool_gate %{
    name: "tool-gate",
    events: ["tool.call.requested"],
    module: ToolGate,
    options: %{}
  }

  defp tmp_overlay!(body) do
    dir = Path.join(System.tmp_dir!(), "omunculus-perm-#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p!(dir)
    path = Path.join(dir, "omunculus.toml")
    File.write!(path, body)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: path}
  end

  defp boot(tmp, max_depth, opts) do
    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, projector} = Projector.start_link(core: core)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: max_depth,
        agents: Keyword.fetch!(opts, :agents),
        config: [
          cwd: tmp.dir,
          config_file: tmp.path,
          env: %{},
          profile: Keyword.get(opts, :profile, "perm")
        ],
        run_opts: [delegation_timeout: 10_000]
      )

    %{core: core, projector: projector, runtime: runtime}
  end

  defp perm_overlay(extra \\ "") do
    tmp_overlay!("""
    [profiles.perm]
    mode = "deny"
    granted = ["counter"]
    human = ["edit"]

    [policy.depth.0]
    mode = "deny"
    granted = ["counter"]
    human = ["edit"]

    [policy.depth.1]
    mode = "deny"
    granted = ["counter"]
    negotiable = ["edit"]

    [workspaces.app]
    roots = ["."]
    mode = "allow"

    [agents.worker]
    prompt = "worker"

    [agents.concierge]
    prompt = "concierge"
    #{extra}
    """)
  end

  test "request_permission appends permission.requested and waits with empty runs" do
    tmp = perm_overlay()

    agents =
      Agents.resolver(
        script: fn _id, _depth, _, _ ->
          [
            Fake.tool_call(
              "request_permission",
              %{"tool" => "edit", "reason" => "patch"},
              "call_rp"
            ),
            Fake.text("done")
          ]
        end
      )

    %{core: core, runtime: runtime} = boot(tmp, 0, agents: agents)

    task = Task.async(fn -> Runtime.request(core, "need edit", timeout: 2_000) end)
    Process.sleep(250)

    assert map_size(Runtime.runs(runtime)) == 0

    requested =
      Harness.await_log(core, fn env ->
        env.type == "permission.requested" and env.payload["tool"] == "edit"
      end)

    assert requested.payload["arbiter"] == "human"
    assert String.starts_with?(requested.payload["request_id"], "req_")

    waiting =
      Harness.await_log(core, fn env ->
        env.type == "run.completed" and env.payload["outcome"] == "waiting"
      end)

    assert requested.payload["request_id"] in waiting.payload["awaiting"]
    Task.shutdown(task, :brutal_kill)
  end

  test "second request_permission for same tool is idempotent" do
    tmp = perm_overlay()

    agents =
      Agents.resolver(
        script: fn _id, _depth, _, _ ->
          [
            Fake.tool_call(
              "request_permission",
              %{"tool" => "edit", "reason" => "one"},
              "call_rp1"
            ),
            Fake.tool_call(
              "request_permission",
              %{"tool" => "edit", "reason" => "two"},
              "call_rp2"
            ),
            Fake.text("done")
          ]
        end
      )

    %{core: core} = boot(tmp, 0, agents: agents)
    task = Task.async(fn -> Runtime.request(core, "need edit", timeout: 2_000) end)
    Process.sleep(300)

    requested =
      core
      |> EventCore.stream(0, type: "permission.requested")
      |> Enum.filter(&(&1.payload["tool"] == "edit"))

    assert length(requested) == 1
    Task.shutdown(task, :brutal_kill)
  end

  test "already granted tool waits on policy then continues with tool exposed" do
    tmp =
      tmp_overlay!("""
      [profiles.perm]
      mode = "deny"
      granted = ["counter", "edit"]
      human = ["write"]

      [policy.depth.0]
      mode = "deny"
      granted = ["counter", "edit"]
      human = ["write"]

      [workspaces.app]
      roots = ["."]
      mode = "allow"
      """)

    agents =
      Agents.resolver(
        script: fn _id, _depth, _, _ ->
          [
            Fake.tool_call(
              "request_permission",
              %{"tool" => "edit", "reason" => "again"},
              "call_rp"
            ),
            Fake.tool_call("counter", %{}, "call_counter"),
            Fake.text("1")
          ]
        end
      )

    %{core: core} = boot(tmp, 0, agents: agents)

    assert {:ok, %{result: "1"}} = Runtime.request(core, "count", timeout: 10_000)
  end

  test "parent arbitration grants and child continuation uses tool" do
    tmp = Harness.tmp_fixture("medium.toml")
    on_exit(fn -> File.rm_rf!(tmp.dir) end)

    overlay = Path.join(tmp.dir, "perm-arbitration.toml")

    File.write!(overlay, """
    [policy.depth.0]
    mode = "deny"
    granted = ["counter", "delegate"]
    negotiable = ["edit"]

    [policy.depth.1]
    mode = "deny"
    granted = ["counter"]
    negotiable = ["edit"]
    """)

    agents =
      Agents.resolver(
        script: fn _agent_id, depth, _ws, _team ->
          if depth == 0 do
            [
              Fake.tool_call(
                "delegate",
                %{"instruction" => "work", "workspace" => "app"},
                "call_del"
              ),
              Fake.text("done")
            ]
          else
            [
              Fake.tool_call(
                "request_permission",
                %{"tool" => "edit", "reason" => "patch"},
                "call_rp"
              ),
              Fake.tool_call("edit", %{"path" => "a.txt", "content" => "x"}, "call_edit"),
              Fake.text("ok")
            ]
          end
        end
      )

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, _projector} = Projector.start_link(core: core)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 1,
        agents: agents,
        config: [cwd: tmp.dir, config_file: overlay, env: %{}, profile: "coding"],
        run_opts: [delegation_timeout: 10_000]
      )

    _task = Task.async(fn -> Runtime.request(core, "delegate work", timeout: 2_000) end)
    Process.sleep(500)

    requested =
      Enum.find(
        EventCore.stream(core, 0, type: "permission.requested"),
        &(&1.payload["tool"] == "edit")
      )

    assert requested.payload["arbiter"] == "parent"

    assert Enum.any?(
             EventCore.stream(core, 0, type: "permission.granted"),
             &(&1.payload["kind"] == "temporary")
           )

    assert Enum.any?(
             EventCore.stream(core, 0, type: "tool.call.requested"),
             &(&1.payload["tool"] == "edit")
           )
  end

  test "human band does not start arbitration run" do
    tmp = perm_overlay()

    agents =
      Agents.resolver(
        script: fn _id, _d, _, _ ->
          [Fake.tool_call("request_permission", %{"tool" => "edit", "reason" => "x"}, "call_rp")]
        end
      )

    %{core: core} = boot(tmp, 0, agents: agents)
    task = Task.async(fn -> Runtime.request(core, "x", timeout: 2_000) end)
    Process.sleep(250)

    assert Enum.any?(
             EventCore.stream(core, 0, type: "permission.requested"),
             &(&1.payload["arbiter"] == "human")
           )

    refute Enum.any?(
             EventCore.stream(core, 0, type: "run.started"),
             &(&1.payload["reason"] == "arbitration")
           )

    Task.shutdown(task, :brutal_kill)
  end

  test "parent arbitration deny blocks child continuation" do
    tmp = Harness.tmp_fixture("medium.toml")
    on_exit(fn -> File.rm_rf!(tmp.dir) end)

    overlay = Path.join(tmp.dir, "perm-deny.toml")

    File.write!(overlay, """
    [policy.depth.0]
    mode = "deny"
    granted = ["counter", "delegate"]
    negotiable = ["edit"]

    [policy.depth.1]
    mode = "deny"
    granted = ["counter"]
    negotiable = ["edit"]
    """)

    agents =
      Agents.resolver(
        script: fn _agent_id, depth, _ws, _team, reason ->
          if reason == "arbitration" do
            [
              Fake.tool_call("deny", %{"reason" => "not now"}, "call_deny"),
              Fake.text("denied")
            ]
          else
            if depth == 0 do
              [
                Fake.tool_call(
                  "delegate",
                  %{"instruction" => "work", "workspace" => "app"},
                  "call_del"
                ),
                Fake.text("done")
              ]
            else
              if reason == "continuation" do
                [
                  Fake.tool_call(
                    "request_permission",
                    %{"tool" => "edit", "reason" => "patch"},
                    "call_rp"
                  ),
                  Fake.text("denied")
                ]
              else
                [
                  Fake.tool_call(
                    "request_permission",
                    %{"tool" => "edit", "reason" => "patch"},
                    "call_rp"
                  ),
                  Fake.tool_call("edit", %{"path" => "a.txt", "content" => "x"}, "call_edit"),
                  Fake.text("ok")
                ]
              end
            end
          end
        end
      )

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, _projector} = Projector.start_link(core: core)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 1,
        agents: agents,
        config: [cwd: tmp.dir, config_file: overlay, env: %{}, profile: "coding"],
        run_opts: [delegation_timeout: 10_000]
      )

    assert {:ok, _} = Runtime.request(core, "delegate work", timeout: 20_000)

    assert Enum.any?(
             EventCore.stream(core, 0, type: "permission.denied"),
             &(&1.payload["reason"] == "not now")
           )

    refute Enum.any?(
             EventCore.stream(core, 0, type: "tool.call.requested"),
             &(&1.payload["tool"] == "edit")
           )
  end

  test "parent escalation leaves request open without child continuation" do
    tmp = Harness.tmp_fixture("medium.toml")
    on_exit(fn -> File.rm_rf!(tmp.dir) end)

    overlay = Path.join(tmp.dir, "perm-escalate.toml")

    File.write!(overlay, """
    [policy.depth.0]
    mode = "deny"
    granted = ["counter", "delegate"]
    negotiable = ["edit"]

    [policy.depth.1]
    mode = "deny"
    granted = ["counter"]
    negotiable = ["edit"]
    """)

    agents =
      Agents.resolver(
        script: fn _agent_id, depth, _ws, _team, reason ->
          if reason == "arbitration" do
            [
              Fake.tool_call("escalate", %{"reason" => "ask human"}, "call_esc"),
              Fake.text("escalated")
            ]
          else
            if depth == 0 do
              [
                Fake.tool_call(
                  "delegate",
                  %{"instruction" => "work", "workspace" => "app"},
                  "call_del"
                ),
                Fake.text("done")
              ]
            else
              [
                Fake.tool_call(
                  "request_permission",
                  %{"tool" => "edit", "reason" => "patch"},
                  "call_rp"
                ),
                Fake.text("waiting")
              ]
            end
          end
        end
      )

    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, _projector} = Projector.start_link(core: core)

    {:ok, _runtime} =
      Runtime.start_link(
        core: core,
        max_depth: 1,
        agents: agents,
        config: [cwd: tmp.dir, config_file: overlay, env: %{}, profile: "coding"],
        run_opts: [delegation_timeout: 10_000]
      )

    task = Task.async(fn -> Runtime.request(core, "delegate work", timeout: 2_000) end)
    Process.sleep(500)

    requested =
      Enum.find(
        EventCore.stream(core, 0, type: "permission.requested"),
        &(&1.payload["tool"] == "edit")
      )

    assert requested
    refute RuntimePermission.resolved_request?(core, requested.payload["request_id"])

    refute Enum.any?(
             EventCore.stream(core, 0, type: "run.started"),
             fn env ->
               env.payload["reason"] == "continuation" and
                 env.work_item_id == requested.work_item_id
             end
           )

    Task.shutdown(task, :brutal_kill)
  end
end
