defmodule Omunculus.RuntimeTest do
  @moduledoc """
  The scenarios of docs/to-be/event-model.md (`conte até 10`) as executable
  fixtures: the causation chain must be linear and in the documented order.
  """
  use ExUnit.Case, async: true

  alias Omunculus.Chat.Fake
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime
  alias Omunculus.Runtime.SpikeAgents

  @chain_types ~w(task.requested task.delegated tool.call.requested tool.call.completed task.completed)

  defp boot(max_depth, agent_opts \\ []) do
    {:ok, core} = EventCore.start_link(path: ":memory:")
    {:ok, projector} = Projector.start_link(core: core)

    agents =
      case Keyword.get(agent_opts, :agents) do
        fun when is_function(fun, 1) -> fun
        _ -> SpikeAgents.resolver(agent_opts)
      end

    {:ok, runtime} =
      Runtime.start_link(
        core: core,
        max_depth: max_depth,
        agents: agents,
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

  defp archive_rows(core) do
    EventCore.query(
      core,
      "SELECT depth, agent_kind, attempt, run_id, parent_run_id FROM ARCHIVE_RUNS ORDER BY depth, attempt"
    )
    |> Enum.map(fn [depth, kind, attempt, run_id, parent] ->
      [start] =
        EventCore.stream(core, 0, run_id: run_id, type: "run.started", limit: 1)

      [completed] =
        EventCore.stream(core, 0, run_id: run_id, type: "run.completed", limit: 1)

      {depth, kind, attempt, start.payload["reason"], completed.payload["outcome"], parent}
    end)
  end

  defp run_started(core, run_id) do
    EventCore.stream(core, 0, run_id: run_id, type: "run.started", limit: 1) |> hd()
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(1..500, nil, fn _, _ ->
      if fun.() do
        {:halt, :ok}
      else
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, :timeout}
        else
          Process.sleep(5)
          {:cont, nil}
        end
      end
    end) == :ok
  end

  defp triple_delegate(instructions) do
    %{
      content: nil,
      tool_calls:
        Enum.zip(["call_a", "call_b", "call_c"], instructions)
        |> Enum.map(fn {id, instruction} ->
          %{
            "id" => id,
            "function" => %{
              "name" => "delegate",
              "arguments" => Jason.encode!(%{"instruction" => instruction})
            }
          }
        end),
      usage: nil
    }
  end

  defp last_tool_result(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "tool", "content" => content} when is_binary(content) ->
        case Regex.run(~r/Result: (.+?)\. Still pending:/, content) do
          [_, result] -> result
          _ -> content
        end

      _ ->
        nil
    end)
  end

  defp three_child_agents do
    fn ctx ->
      reason = Map.get(ctx, :reason, "initial")
      checkpoint = Map.get(ctx, :checkpoint, %{})
      messages? = is_list(Map.get(checkpoint, "messages") || Map.get(checkpoint, :messages))

      if ctx.depth == 0 do
        turns =
          if reason in ["continuation", "retry"] or messages? do
            [fn messages -> Fake.text(last_tool_result(messages)) end]
          else
            [triple_delegate(["A", "B", "C"])]
          end

        %{
          agent_id: "leader@custom",
          kind: "concierge",
          model: "fake",
          tools: ["delegate"],
          max_turns: 6,
          chat: Fake.new(turns)
        }
      else
        %{
          agent_id: "worker@custom",
          kind: "worker",
          model: "fake",
          tools: [],
          max_turns: 2,
          chat: Fake.new([Fake.text("ok")])
        }
      end
    end
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

    [[root_initial_run]] =
      EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 0 AND attempt = 1")

    assert [
             {0, "concierge", 1, "initial", "waiting", nil},
             {0, "concierge", 2, "continuation", "completed", nil},
             {1, "worker", 1, "initial", "completed", ^root_initial_run}
           ] = archive_rows(core)

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

    rows = archive_rows(core)

    assert length(rows) == 5

    assert Enum.count(rows, fn {depth, kind, _attempt, _reason, outcome, _parent} ->
             depth == 0 and kind == "concierge" and outcome == "waiting"
           end) == 1

    assert Enum.count(rows, fn {depth, kind, _attempt, _reason, outcome, _parent} ->
             depth == 1 and kind == "concierge" and outcome == "waiting"
           end) == 1

    assert Enum.count(rows, fn {depth, kind, attempt, reason, outcome, _parent} ->
             depth == 2 and kind == "worker" and attempt == 1 and reason == "initial" and
               outcome == "completed"
           end) == 1

    completed_rows =
      rows
      |> Enum.filter(fn {_, _, _, _, outcome, _} -> outcome == "completed" end)
      |> Enum.sort_by(fn {depth, _, attempt, _, _, _} -> {-depth, attempt} end)

    [[root_initial_run]] =
      EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 0 AND attempt = 1")

    [[depth1_initial_run]] =
      EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 1 AND attempt = 1")

    assert [
             {2, "worker", 1, "initial", "completed", ^depth1_initial_run},
             {1, "concierge", 2, "continuation", "completed", ^root_initial_run},
             {0, "concierge", 2, "continuation", "completed", nil}
           ] = completed_rows

    [[worker_run_id]] =
      EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 2 AND attempt = 1")

    [[depth1_cont_run_id]] =
      EventCore.query(core, "SELECT run_id FROM ARCHIVE_RUNS WHERE depth = 1 AND attempt = 2")

    worker_start = run_started(core, worker_run_id)
    depth1_cont_start = run_started(core, depth1_cont_run_id)

    assert worker_start.payload["parent_run_id"] == depth1_initial_run
    assert worker_start.payload["originating_run_id"] == root_initial_run
    assert depth1_cont_start.payload["parent_run_id"] == root_initial_run
    assert depth1_cont_start.payload["originating_run_id"] == root_initial_run
  end

  test "the same configuration serves different depths: kind is capability, not position" do
    %{core: core} = boot(2)
    {:ok, %{requested: requested}} = Runtime.request(core, "conte até 3")

    starts =
      core
      |> EventCore.stream(0, correlation_id: requested.correlation_id, type: "run.started")
      |> Enum.filter(&(&1.payload["attempt"] == 1))
      |> Enum.map(&{&1.payload["depth"], &1.payload["agent_id"]})

    assert starts == [{0, "concierge@spike"}, {1, "concierge@spike"}, {2, "worker@spike"}]
  end

  test "a waiting root run is not tracked live; runs drain when the request completes" do
    %{core: core, runtime: runtime} = boot(1)
    correlation_id = Envelope.generate_id("corr")
    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    task =
      Task.async(fn ->
        Runtime.request(core, "conte até 10", correlation_id: correlation_id, timeout: 20_000)
      end)

    assert_receive {:event_core,
                    %Envelope{type: "run.completed", payload: %{"outcome" => "waiting"}}},
                   5_000

    assert wait_until(
             fn -> not Enum.any?(Runtime.runs(runtime), fn {_, r} -> r.depth == 0 end) end,
             2_000
           )

    assert {:ok, %{result: "10"}} = Task.await(task, 65_000)
    assert wait_until(fn -> map_size(Runtime.runs(runtime)) == 0 end, 5_000)
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
    {:ok, %{result: "3", requested: requested}} = Runtime.request(core, "conte até 3")
    assert Enum.map(chain(core, requested.correlation_id), & &1.type) == expected_types(0, 3)
  end

  @tag timeout: 120_000
  test "a crashed worker is recorded as run.failed and resumed as a new attempt from its checkpoint" do
    %{core: core, projector: projector, runtime: runtime} = boot(1, delay_ms: 40)
    correlation_id = Envelope.generate_id("corr")
    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    task =
      Task.async(fn ->
        Runtime.request(core, "conte até 10", correlation_id: correlation_id, timeout: 60_000)
      end)

    assert_receive {:event_core, %Envelope{type: "tool.call.completed", payload: %{"new" => 3}}},
                   5_000

    {_run_id, worker} = Enum.find(Runtime.runs(runtime), fn {_, r} -> r.depth == 1 end)
    child = worker.work_item_id
    Process.exit(worker.pid, :kill)

    assert_receive {:event_core, %Envelope{type: "run.failed", work_item_id: ^child} = failed},
                   5_000

    assert failed.payload["crashed"] == true
    refute_receive {:event_core, %Envelope{type: "task.completed"}}, 200

    {:ok, _} =
      Runtime.resume(core, child, correlation_id: correlation_id, causation_id: failed.event_id)

    assert {:ok, %{result: "10"}} = Task.await(task, 65_000)
    :ok = Projector.sync(projector)

    assert [[1, "failed"], [2, "completed"]] =
             EventCore.query(
               core,
               "SELECT attempt, status FROM ARCHIVE_RUNS WHERE work_item_id = ? ORDER BY attempt",
               [child]
             )

    [_, second_start] =
      EventCore.stream(core, 0, work_item_id: child, type: "run.started")

    assert second_start.payload["reason"] == "retry"

    checkpoint = get_in(second_start.payload, ["checkpoint", "counter", "value"])
    assert is_integer(checkpoint) and checkpoint >= 3

    attempt2_calls =
      EventCore.stream(core, 0, run_id: second_start.run_id, type: "tool.call.completed")

    assert Enum.map(attempt2_calls, & &1.payload["new"]) == Enum.to_list((checkpoint + 1)..10)

    [child_done, root_done] =
      EventCore.stream(core, 0, correlation_id: correlation_id, type: "task.completed")

    assert child_done.run_id == second_start.run_id
    assert root_done.causation_id == child_done.event_id

    assert [["completed", "10"]] =
             EventCore.query(
               core,
               "SELECT status, result FROM WORK_ITEMS WHERE work_item_id = ?",
               [child]
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

  test "a leader with three children completes after the last observation" do
    %{core: core, projector: projector} = boot(1, agents: three_child_agents())
    {:ok, %{result: result, requested: requested}} = Runtime.request(core, "fan out")

    root_wi = requested.work_item_id

    first_waiting =
      EventCore.stream(core, 0, work_item_id: root_wi, type: "run.completed")
      |> Enum.find(&(Map.get(&1.payload, "outcome") == "waiting"))

    refute is_nil(first_waiting)
    assert length(first_waiting.payload["awaiting"]) == 3

    continuation_starts =
      EventCore.stream(core, 0, work_item_id: root_wi, type: "run.started")
      |> Enum.filter(&(Map.get(&1.payload, "reason") == "continuation"))

    assert length(continuation_starts) == 3

    # Continuations must be serial: each finishes before the next starts.
    cont_starts = Enum.sort_by(continuation_starts, & &1.sequence)

    Enum.chunk_every(cont_starts, 2, 1, :discard)
    |> Enum.each(fn [prev, next] ->
      prev_done =
        EventCore.stream(core, 0, run_id: prev.run_id, type: "run.completed", limit: 1) |> hd()

      assert prev_done.sequence < next.sequence
    end)

    for start <- continuation_starts do
      assert [_model] =
               EventCore.stream(core, 0, run_id: start.run_id, type: "model.call.completed")
    end

    continuation_waiting =
      EventCore.stream(core, 0, work_item_id: root_wi, type: "run.completed")
      |> Enum.filter(fn env ->
        env.payload["outcome"] == "waiting" and
          match?(
            %Envelope{type: "run.started", payload: %{"reason" => "continuation"}},
            EventCore.stream(core, 0, run_id: env.run_id, type: "run.started", limit: 1) |> hd()
          )
      end)

    assert length(continuation_waiting) == 2

    for waiting <- continuation_waiting do
      notes = get_in(waiting.payload, ["checkpoint", "notes"])
      assert is_binary(notes) and notes != ""

      assert EventCore.stream(core, 0,
               work_item_id: root_wi,
               run_id: waiting.run_id,
               type: "task.completed",
               limit: 1
             ) == []
    end

    root_completions =
      EventCore.stream(core, 0, work_item_id: root_wi, type: "task.completed")

    assert length(root_completions) == 1

    :ok = Projector.sync(projector)
    assert result == "ok"
  end
end
