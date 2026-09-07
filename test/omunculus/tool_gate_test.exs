defmodule Omunculus.ToolGateTest do
  use ExUnit.Case, async: true

  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Events
  alias Omunculus.Interceptors.ToolGate

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

  setup do
    {:ok, core} = EventCore.start_link(path: ":memory:", interceptors: [@tool_gate])
    {:ok, projector} = Projector.start_link(core: core)
    %{core: core, projector: projector}
  end

  test "Events.request_id is stable and shared by children of the same grant root" do
    assert Events.request_id("wi-task", "edit") == Events.request_id("wi-task", "edit")
    assert Events.request_id("wi-task", "edit") != Events.request_id("wi-task", "write")
    assert Events.request_id("wi-task", "edit") != Events.request_id("wi-other", "edit")
    assert String.starts_with?(Events.request_id("wi-task", "edit"), "req_")
  end

  test "grant_root_work_item_id resolves depth-1 and deeper lineages", %{
    core: core,
    projector: projector
  } do
    seed_lineage(core, projector)

    {:ok, root} =
      EventCore.transaction(core, fn conn ->
        Events.grant_root_work_item_id(conn, "wi-root")
      end)

    {:ok, child} =
      EventCore.transaction(core, fn conn ->
        Events.grant_root_work_item_id(conn, "wi-child")
      end)

    {:ok, grand} =
      EventCore.transaction(core, fn conn ->
        Events.grant_root_work_item_id(conn, "wi-grand")
      end)

    assert root == "wi-root"
    assert child == "wi-child"
    assert grand == child
    assert Events.request_id(child, "edit") == Events.request_id(grand, "edit")
  end

  test "ToolGate allows pinned tools and temporary ancestor grants", %{
    core: core,
    projector: projector
  } do
    seed_work_items(core, projector)

    run_id = "run-child"
    corr = "corr-grant"

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          causation_id: "evt-run",
          correlation_id: corr,
          work_item_id: "wi-child",
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

    assert deliver_tool(core, started, run_id, "wi-child", "counter")

    req_id = Events.request_id("wi-child", "edit")

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        causation_id: "evt-perm",
        correlation_id: corr,
        work_item_id: "wi-child",
        run_id: run_id,
        payload: %{request_id: req_id, tool: "edit", reason: "patch"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        correlation_id: corr,
        work_item_id: "wi-child",
        payload: %{request_id: req_id, kind: "temporary", granter: "human:test"}
      )
    )

    assert deliver_tool(core, started, run_id, "wi-child", "edit")
  end

  test "ToolGate rejects unpinned tools without a grant", %{core: core, projector: projector} do
    seed_work_items(core, projector)

    started = run_started(core, "run-child", "wi-child")
    refute deliver_tool(core, started, "run-child", "wi-child", "edit")
  end

  test "ToolGate rejects after permission.revoked", %{core: core, projector: projector} do
    seed_work_items(core, projector)
    run_id = "run-child"
    corr = "corr-revoke"
    started = run_started(core, run_id, "wi-child", corr)

    req_id = Events.request_id("wi-child", "edit")

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        causation_id: "evt-perm",
        correlation_id: corr,
        work_item_id: "wi-child",
        run_id: run_id,
        payload: %{request_id: req_id, tool: "edit", reason: "patch"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        correlation_id: corr,
        work_item_id: "wi-child",
        payload: %{request_id: req_id, kind: "temporary", granter: "human:test"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.revoked",
        correlation_id: corr,
        work_item_id: "wi-child",
        payload: %{request_id: req_id}
      )
    )

    refute deliver_tool(core, started, run_id, "wi-child", "edit")
  end

  test "sibling grant roots do not share lineage grants", %{core: core, projector: projector} do
    EventCore.append!(
      core,
      Envelope.command("task.requested", work_item_id: "wi-root", payload: %{instruction: "root"})
    )

    for {parent, child} <- [{"wi-root", "wi-a"}, {"wi-root", "wi-b"}] do
      EventCore.append!(
        core,
        Envelope.event("task.delegated",
          causation_id: "evt-parent",
          work_item_id: parent,
          payload: %{
            instruction: "task",
            child_work_item_id: child,
            to_depth: 1,
            parent_run_id: "run-root",
            originating_run_id: "run-root"
          }
        )
      )
    end

    :ok = Projector.sync(projector)

    req_id = Events.request_id("wi-a", "edit")

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        causation_id: "evt-perm",
        correlation_id: "corr-sib",
        work_item_id: "wi-a",
        run_id: "run-a",
        payload: %{request_id: req_id, tool: "edit", reason: "patch"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        correlation_id: "corr-sib",
        work_item_id: "wi-a",
        payload: %{request_id: req_id, kind: "temporary", granter: "human:test"}
      )
    )

    started = run_started(core, "run-b", "wi-b", "corr-sib")
    refute deliver_tool(core, started, "run-b", "wi-b", "edit")
  end

  test "child of grantee inherits ToolGate allow", %{core: core, projector: projector} do
    seed_work_items(core, projector, grandchild: true)

    req_id = Events.request_id("wi-child", "edit")

    EventCore.append!(
      core,
      Envelope.event("permission.requested",
        causation_id: "evt-perm",
        correlation_id: "corr-inherit",
        work_item_id: "wi-child",
        run_id: "run-child",
        payload: %{request_id: req_id, tool: "edit", reason: "patch"}
      )
    )

    EventCore.append!(
      core,
      Envelope.command("permission.granted",
        correlation_id: "corr-inherit",
        work_item_id: "wi-child",
        payload: %{request_id: req_id, kind: "temporary", granter: "human:test"}
      )
    )

    started = run_started(core, "run-grand", "wi-grand", "corr-inherit")
    assert deliver_tool(core, started, "run-grand", "wi-grand", "edit")
  end

  test "permission.granted kind=permanent from run arbiter is rejected", %{core: core} do
    assert {:error, {:permanent_requires_human, "run:parent"}} =
             EventCore.append(
               core,
               Envelope.command("permission.granted",
                 payload: %{
                   request_id: "req-1",
                   kind: "permanent",
                   granter: "run:parent"
                 }
               )
             )

    assert {:ok, _} =
             EventCore.append(
               core,
               Envelope.command("permission.granted",
                 payload: %{
                   request_id: "req-2",
                   kind: "permanent",
                   granter: "human:cli"
                 }
               )
             )
  end

  defp seed_lineage(core, projector) do
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
          instruction: "child",
          child_work_item_id: "wi-child",
          to_depth: 1,
          parent_run_id: "run-root",
          originating_run_id: "run-root"
        }
      )
    )

    EventCore.append!(
      core,
      Envelope.event("task.delegated",
        causation_id: "evt-parent",
        work_item_id: "wi-child",
        payload: %{
          instruction: "grandchild",
          child_work_item_id: "wi-grand",
          to_depth: 2,
          parent_run_id: "run-child",
          originating_run_id: "run-root"
        }
      )
    )

    :ok = Projector.sync(projector)
  end

  defp seed_work_items(core, projector, opts \\ []) do
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
          instruction: "child",
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
            instruction: "grandchild",
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

  defp run_started(core, run_id, work_item_id, corr \\ "corr") do
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

  defp deliver_tool(core, started, run_id, work_item_id, tool) do
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
