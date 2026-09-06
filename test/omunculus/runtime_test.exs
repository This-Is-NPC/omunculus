defmodule Omunculus.RuntimeTest do
  @moduledoc """
  The scenarios of docs/to-be/event-model.md (`conte até 10`) as executable
  fixtures: the causation chain must be linear and in the documented order.
  """
  use ExUnit.Case, async: true

  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  @chain_types ~w(task.requested task.delegated tool.call.requested tool.call.completed task.completed)

  defp boot(max_depth, agent_opts \\ []) do
    {:ok, core} = EventCore.start_link(path: ":memory:")
    {:ok, projector} = Projector.start_link(core: core)

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: max_depth,
        agents: SpikeAgents.resolver(agent_opts),
        run_opts: [delegation_timeout: 10_000]
      )

    %{core: core, projector: projector, runtime: runtime}
  end

  defp chain(core, correlation_id) do
    core
    |> EventCore.stream(0, correlation_id: correlation_id)
    |> Enum.filter(&(&1.type in @chain_types))
  end

  defp assert_linear!(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [prev, next] ->
      assert next.causation_id == prev.event_id,
             "#{next.type} (#{next.event_id}) should be caused by #{prev.type} (#{prev.event_id})"
    end)
  end

  defp expected_types(depth, rounds \\ 10) do
    ["task.requested"] ++
      List.duplicate("task.delegated", depth) ++
      List.flatten(List.duplicate(["tool.call.requested", "tool.call.completed"], rounds)) ++
      List.duplicate("task.completed", depth + 1)
  end

  test "scenario 3: depth 1 without interceptor, linear causation chain" do
    %{core: core, projector: projector} = boot(1)

    {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

    events = chain(core, requested.correlation_id)
    assert Enum.map(events, & &1.type) == expected_types(1)
    assert hd(events).causation_id == nil
    assert_linear!(events)

    completed = Enum.filter(events, &(&1.type == "tool.call.completed"))

    assert Enum.map(completed, &{&1.payload["previous"], &1.payload["new"]}) ==
             Enum.map(1..10, &{&1 - 1, &1})

    [leaf, root] = Enum.filter(events, &(&1.type == "task.completed"))
    assert leaf.payload["depth"] == 1 and root.payload["depth"] == 0

    :ok = Projector.sync(projector)

    assert [[0, "concierge", nil, "completed"], [1, "worker", root_run, "completed"]] =
             EventCore.query(
               core,
               "SELECT depth, agent_kind, parent_run_id, status FROM ARCHIVE_RUNS ORDER BY depth"
             )

    assert [[^root_run]] =
             EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 0")

    assert [["completed", "10"], ["completed", "10"]] =
             EventCore.query(core, "SELECT status, result FROM WORK_ITEMS ORDER BY created_at")

    assert [[1]] = EventCore.query(core, "SELECT count(*) FROM WORK_ITEM_DEPENDENCIES")
    assert [[n]] = EventCore.query(core, "SELECT count(*) FROM ARCHIVE_MODEL_CALLS")
    assert n == 2 + 11
  end

  test "scenario 4: depth 2 without interceptor, report climbs the dynamic tree" do
    %{core: core, projector: projector} = boot(2)

    {:ok, %{result: "10", requested: requested}} = Runtime.request(core, "conte até 10")

    events = chain(core, requested.correlation_id)
    assert Enum.map(events, & &1.type) == expected_types(2)
    assert_linear!(events)

    assert Enum.map(Enum.filter(events, &(&1.type == "task.completed")), & &1.payload["depth"]) ==
             [2, 1, 0]

    :ok = Projector.sync(projector)

    runs =
      EventCore.query(
        core,
        "SELECT depth, run_id, parent_run_id, originating_run_id FROM ARCHIVE_RUNS ORDER BY depth"
      )

    assert [[0, r0, nil, nil], [1, r1, r0, r0], [2, _r2, r1, r0]] = runs
  end

  test "the same configuration serves different depths: kind is capability, not position" do
    %{core: core} = boot(2)
    {:ok, %{requested: requested}} = Runtime.request(core, "conte até 3")

    starts =
      core
      |> EventCore.stream(0, correlation_id: requested.correlation_id, type: "run.started")
      |> Enum.map(&{&1.payload["depth"], &1.payload["agent_id"]})

    assert starts == [{0, "concierge@spike"}, {1, "concierge@spike"}, {2, "worker@spike"}]
  end

  test "replay rebuilds identical projections and redelivery is a no-op" do
    %{core: core, projector: projector} = boot(1)
    {:ok, %{requested: requested}} = Runtime.request(core, "conte até 5")
    :ok = Projector.sync(projector)

    before = Projector.snapshot(core)
    cursor = Projector.cursor(projector)
    count = length(EventCore.stream(core, 0))

    :ok = Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
    assert Projector.cursor(projector) == cursor

    # Redeliver every envelope of the run: nothing new is appended or applied.
    for env <- EventCore.stream(core, 0, correlation_id: requested.correlation_id) do
      assert {:ok, ^env} = EventCore.append(core, env)
    end

    :ok = Projector.sync(projector)
    assert length(EventCore.stream(core, 0)) == count
    assert Projector.snapshot(core) == before
  end

  test "an idempotent re-submission returns the first result without a new run" do
    %{core: core} = boot(1)

    {:ok, first} = Runtime.request(core, "conte até 4", idempotency_key: "cli-1")
    count = length(EventCore.stream(core, 0))

    {:ok, second} = Runtime.request(core, "conte até 4", idempotency_key: "cli-1")
    assert second.requested.event_id == first.requested.event_id
    assert second.result == "4"
    assert length(EventCore.stream(core, 0)) == count

    assert {:error, {:idempotency_conflict, "cli-1"}} =
             EventCore.append(
               core,
               Envelope.command("task.requested",
                 idempotency_key: "cli-1",
                 payload: %{instruction: "conte até 99", depth: 0}
               )
             )
  end

  test "delegation beyond max depth is refused at the node, not by configuration" do
    %{core: core} = boot(0)
    # depth 0 is already max_depth: the worker counts directly.
    {:ok, %{result: "3", requested: requested}} = Runtime.request(core, "conte até 3")
    assert Enum.map(chain(core, requested.correlation_id), & &1.type) == expected_types(0, 3)
  end

  test "a crashed worker is recorded as run.failed and resumed as a new attempt from its checkpoint" do
    %{core: core, projector: projector, runtime: runtime} = boot(1, delay_ms: 40)
    correlation_id = Envelope.generate_id("corr")
    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    task =
      Task.async(fn ->
        Runtime.request(core, "conte até 10", correlation_id: correlation_id, timeout: 20_000)
      end)

    # Let the worker count to 3, then kill its process (not the runtime, not the core).
    assert_receive {:event_core,
                    %Envelope{type: "tool.call.completed", payload: %{"new" => 3}} = at3},
                   5_000

    {_run_id, worker} = Enum.find(Runtime.runs(runtime), fn {_, r} -> r.depth == 1 end)
    Process.exit(worker.pid, :kill)

    assert_receive {:event_core, %Envelope{type: "run.failed", work_item_id: child} = failed},
                   5_000

    assert failed.payload["crashed"] == true
    assert child == at3.work_item_id
    refute_receive {:event_core, %Envelope{type: "task.completed"}}, 200

    {:ok, _} =
      Runtime.resume(core, child, correlation_id: correlation_id, causation_id: failed.event_id)

    assert {:ok, %{result: "10"}} = Task.await(task, 25_000)
    :ok = Projector.sync(projector)

    assert [[1, "failed"], [2, "completed"]] =
             EventCore.query(
               core,
               "SELECT attempt, status FROM ARCHIVE_RUNS WHERE work_item_id = ? ORDER BY attempt",
               [child]
             )

    [_, second_start] =
      EventCore.stream(core, 0, work_item_id: child, type: "run.started")

    checkpoint = get_in(second_start.payload, ["checkpoint", "counter", "value"])
    assert is_integer(checkpoint) and checkpoint >= 3

    attempt2_calls =
      EventCore.stream(core, 0, run_id: second_start.run_id, type: "tool.call.completed")

    assert Enum.map(attempt2_calls, & &1.payload["new"]) == Enum.to_list((checkpoint + 1)..10)

    # The parent's completion is caused by the child's completion from attempt 2.
    [child_done, root_done] =
      EventCore.stream(core, 0, correlation_id: correlation_id, type: "task.completed")

    assert child_done.run_id == second_start.run_id
    assert root_done.causation_id == child_done.event_id

    assert [["completed", "10"]] =
             EventCore.query(
               core,
               "SELECT status, result FROM WORK_ITEMS WHERE work_item_id = ?",
               [
                 child
               ]
             )
  end

  test "resume is rejected while the run is still open or already completed" do
    %{core: core} = boot(1)
    {:ok, %{requested: requested}} = Runtime.request(core, "conte até 2")
    :ok = EventCore.subscribe(core, correlation_id: requested.correlation_id)

    {:ok, _} =
      Runtime.resume(core, requested.work_item_id, correlation_id: requested.correlation_id)

    assert_receive {:event_core,
                    %Envelope{type: "task.resume_rejected", payload: %{"reason" => reason}}},
                   2_000

    assert reason =~ "already_completed"
  end
end
