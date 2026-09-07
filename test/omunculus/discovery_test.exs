defmodule Omunculus.DiscoveryTest do
  use ExUnit.Case, async: true
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Tools.Directory
  alias Omunculus.Tool.Context

  setup do
    core = start_supervised!({EventCore, path: ":memory:"})
    projector = start_supervised!({Projector, core: core})
    %{core: core, projector: projector}
  end

  defp node(core, wi, team, workspace, scope, bands, session \\ "s") do
    activation =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          session_id: session,
          workspace_id: workspace,
          work_item_id: wi,
          payload: %{instruction: "work", workspace: workspace}
        )
      )

    EventCore.append!(
      core,
      Envelope.event("run.started",
        session_id: session,
        causation_id: activation.event_id,
        workspace_id: workspace,
        work_item_id: wi,
        run_id: "run-" <> wi,
        payload: %{
          attempt: 1,
          depth: 2,
          agent_id: "worker",
          agent_kind: "worker",
          reason: "initial",
          team: team,
          workspace: workspace,
          directory_scope: scope,
          tools: bands
        }
      )
    )
  end

  defp bands(granted, negotiable \\ []),
    do: %{granted: granted, negotiable: negotiable, human: [], forbidden: []}

  defp request(core, wi, team) do
    EventCore.append!(
      core,
      Envelope.event("task.requested",
        session_id: "s",
        causation_id: List.last(EventCore.stream(core, 0)).event_id,
        workspace_id: "app",
        work_item_id: wi,
        run_id: "run-" <> wi,
        payload: %{
          instruction: "peer work",
          requested_by: "run:run-" <> wi,
          child_work_item_id: "new-child",
          team: team
        }
      )
    )
  end

  defp rejected?(core, event) do
    Enum.any?(
      EventCore.stream(core, 0, type: "delivery.rejected"),
      &(&1.causation_id == event.event_id)
    )
  end

  test "negotiable is not executable authority without a grant", %{
    core: core,
    projector: projector
  } do
    node(core, "opaque", "review", "app", "session", bands([], ["request_work"]))
    Projector.sync(projector)
    assert rejected?(core, request(core, "opaque", "edit"))
  end

  test "subtree blocks other teams even when request_work is granted", %{core: core} do
    node(core, "opaque", "review", "app", "subtree", bands(["request_work"]))
    assert rejected?(core, request(core, "opaque", "edit"))
    refute rejected?(core, request(core, "opaque", "review"))
  end

  test "session discovery permits another team", %{core: core} do
    node(core, "opaque", "review", "app", "session", bands(["request_work"]))
    refute rejected?(core, request(core, "opaque", "edit"))
  end

  test "directory uses actual team and session membership for opaque IDs and comments", %{
    core: core,
    projector: projector
  } do
    node(core, "opaque-1", "review", "app", "subtree", bands([]))
    node(core, "review-misleading-id", "edit", "app", "subtree", bands([]))
    node(core, "opaque-2", "review", "infra", "subtree", bands([]))
    node(core, "opaque-3", "review", "app", "subtree", bands([]), "other-session")

    for wi <- ["opaque-1", "review-misleading-id", "opaque-2", "opaque-3"] do
      EventCore.append!(
        core,
        Envelope.command("task.commented",
          work_item_id: wi,
          payload: %{body: "finding for " <> wi, kind: "response"}
        )
      )
    end

    Projector.sync(projector)

    ctx =
      Context.new(Omunculus.FS.Memory.new(%{}), %{
        core: core,
        directory_scope: "subtree",
        team: "review",
        workspace_id: "app",
        session_id: "s"
      })

    {:ok, body, _} = Directory.call(%{}, ctx)
    result = Jason.decode!(body)
    assert Enum.map(result["open_work_items"], & &1["work_item_id"]) == ["opaque-1"]
    assert Enum.map(result["comments"], & &1["work_item_id"]) == ["opaque-1"]

    {:ok, body, _} =
      Directory.call(%{}, %{ctx | options: Map.put(ctx.options, :directory_scope, "session")})

    assert Jason.decode!(body)["open_work_items"] |> Enum.map(& &1["work_item_id"]) |> Enum.sort() ==
             ["opaque-1", "opaque-2", "review-misleading-id"]
  end
end
