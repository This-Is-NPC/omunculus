defmodule Omunculus.WorkflowTest do
  use ExUnit.Case, async: false
  alias Omunculus.{Chat.Fake, Config, EventCore, Runtime}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents

  defp report(done, comment, extra \\ %{}),
    do: Fake.text(Jason.encode!(Map.merge(%{completed: done, comment: comment}, extra)))

  defp delegate,
    do:
      Fake.tool_call("delegate", %{
        "instruction" => "produce evidence",
        "comment" => "Delegated execution; review the returned evidence."
      })

  defp setup_runtime(script, depth \\ 0, retries \\ 1, config \\ Config.empty()) do
    core = start_supervised!({EventCore, path: ":memory:"})
    projector = start_supervised!({Projector, core: core})

    resolver = fn ctx ->
      chat = Fake.new(script.(ctx)) |> Map.put(:model, "workflow-test")
      agent = Agents.resolve(Map.put(ctx, :config, config), %{chat: chat})

      %{
        agent
        | tools: if(ctx.depth < depth, do: ["delegate"], else: ["counter"]),
          max_retries: retries,
          max_turns: 4
      }
    end

    opts = [
      core: core,
      max_depth: depth,
      agents: resolver,
      run_opts: [fs: Omunculus.FS.Memory.new()]
    ]

    runtime = start_supervised!({Runtime, opts})
    {core, projector, runtime, opts}
  end

  defp await(fun, n \\ 400)
  defp await(_fun, 0), do: flunk("condition did not settle")

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, n - 1)
        )
  end

  test "incomplete report retries with comment and confirmed counter state" do
    owner = self()

    {core, projector, runtime, _} =
      setup_runtime(fn ctx ->
        if ctx.reason == "retry" do
          [
            fn messages ->
              send(owner, {:retry_messages, messages})
              Fake.tool_call("counter", %{})
            end,
            report(true, "Confirmed counter 2")
          ]
        else
          [
            Fake.tool_call("counter", %{}),
            report(false, "One increment is confirmed. Continue once, do not restart.")
          ]
        end
      end)

    assert {:ok, %{result: "Confirmed counter 2"}} =
             Runtime.request(core, "increment twice", timeout: 3000)

    await(fn -> Runtime.runs(runtime) == %{} end)
    assert_receive {:retry_messages, messages}

    assert Enum.any?(
             messages,
             &String.contains?(&1["content"] || "", "One increment is confirmed")
           )

    assert Enum.count(messages, &(&1["role"] == "system")) == 1
    assert hd(messages)["content"] =~ "Run reason: retry"

    values =
      EventCore.stream(core, 0, type: "tool.call.completed")
      |> Enum.filter(&(&1.payload["tool"] == "counter"))
      |> Enum.map(& &1.payload["new"])

    assert values == [1, 2]
    assert length(EventCore.stream(core, 0, type: "run.started")) == 2
    Projector.sync(projector)
    assert [[2]] = EventCore.query(core, "SELECT count(*) FROM COMMENTS WHERE kind = 'run'")
  end

  test "max retries emits one durable human break and restart does not reset budget" do
    {core, projector, runtime, opts} =
      setup_runtime(fn _ -> [report(false, "Need assistance; evidence insufficient")] end)

    env =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: "budget",
          payload: %{instruction: "work"}
        )
      )

    await(fn -> EventCore.stream(core, 0, type: "task.commented") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    assert length(EventCore.stream(core, 0, type: "run.started")) == 2
    assert length(EventCore.stream(core, 0, type: "task.break")) == 1
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, Keyword.put(opts, :recover, true)})
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "task.commented")) == 1
    brk = hd(EventCore.stream(core, 0, type: "task.break"))

    EventCore.append!(
      core,
      Envelope.command("task.commented",
        correlation_id: env.correlation_id,
        work_item_id: "budget",
        payload: %{
          kind: "response",
          request_id: brk.event_id,
          body: Jason.encode!(%{completed: true, comment: "Human verified existing work"})
        }
      )
    )

    await(fn -> EventCore.stream(core, 0, type: "task.completed") != [] end)
    Projector.sync(projector)

    assert [["completed"]] =
             EventCore.query(core, "SELECT status FROM WORK_ITEMS WHERE work_item_id = 'budget'")

    assert length(EventCore.stream(core, 0, type: "run.started")) == 2
    EventCore.redeliver(core, brk.event_id)
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "task.completed")) == 1
    stop_supervised!(Runtime)
    Projector.sync(projector)
    before = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
  end

  test "parent recognizes completed child on break without reexecuting it" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "assessment" ->
              [report(true, "I verified the existing child effect")]

            ctx.reason == "continuation" ->
              [report(true, "Root consolidated")]

            ctx.depth == 0 ->
              [delegate()]

            true ->
              [
                Fake.tool_call("counter", %{}),
                report(false, "Effect exists but I cannot establish completion")
              ]
          end
        end,
        1,
        0
      )

    assert {:ok, %{result: "Root consolidated"}} = Runtime.request(core, "work", timeout: 3000)
    await(fn -> Runtime.runs(runtime) == %{} end)

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 1

    assert length(EventCore.stream(core, 0, type: "task.completed")) == 2
    starts = EventCore.stream(core, 0, type: "run.started")
    review = Enum.find(starts, &(&1.payload["reason"] == "assessment"))
    assert review.payload["tools"]["granted"] == ["delegate"]

    assert Enum.map(starts, & &1.payload["reason"]) == [
             "initial",
             "initial",
             "assessment",
             "continuation"
           ]
  end

  test "break escalates through both responsible levels to the human" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "break" ->
              [report(false, "Cannot resolve at this level", %{break: true})]

            ctx.reason in ["continuation", "assessment"] ->
              [report(true, "Consolidated")]

            ctx.depth < 2 ->
              [delegate()]

            true ->
              [report(false, "Need intervention", %{break: true})]
          end
        end,
        2,
        0
      )

    EventCore.append!(
      core,
      Envelope.command("task.requested", work_item_id: "root", payload: %{instruction: "work"})
    )

    await(fn -> EventCore.stream(core, 0, type: "task.commented") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    breaks = EventCore.stream(core, 0, type: "task.break")
    assert length(breaks) == 3
    assert List.last(breaks).payload["reviewer"] == nil
    request = hd(EventCore.stream(core, 0, type: "task.commented"))

    EventCore.append!(
      core,
      Envelope.command("task.commented",
        work_item_id: request.work_item_id,
        correlation_id: request.correlation_id,
        payload: %{
          kind: "response",
          request_id: request.payload["request_id"],
          body: Jason.encode!(%{completed: true, comment: "Human accepted"})
        }
      )
    )

    await(fn -> length(EventCore.stream(core, 0, type: "task.completed")) == 3 end)
    await(fn -> Runtime.runs(runtime) == %{} end)
  end

  test "handoff without model comment cannot create child effects" do
    {core, _, _, _} =
      setup_runtime(
        fn ctx ->
          if ctx.depth == 0 do
            [
              Fake.tool_call("delegate", %{"instruction" => "work"}),
              report(true, "No delegation occurred")
            ]
          else
            [report(true, "unexpected child")]
          end
        end,
        1
      )

    assert {:ok, _} = Runtime.request(core, "work", timeout: 3000)
    assert EventCore.stream(core, 0, type: "task.delegated") == []
  end

  test "parent incomplete comment resumes the child without repeating confirmed effects" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.depth == 0 and ctx.reason == "initial" ->
              [delegate()]

            ctx.depth == 0 and ctx.attempt == 2 ->
              [report(false, "Only one increment exists; perform the second increment.")]

            ctx.depth == 0 ->
              [report(true, "Verified two increments")]

            true ->
              [Fake.tool_call("counter", %{}), report(true, "Counter execution reported")]
          end
        end,
        1,
        1
      )

    assert {:ok, %{result: "Verified two increments"}} =
             Runtime.request(core, "increment twice", timeout: 3000)

    await(fn -> Runtime.runs(runtime) == %{} end)

    calls =
      EventCore.stream(core, 0, type: "tool.call.completed")
      |> Enum.filter(&(&1.payload["tool"] == "counter"))

    assert Enum.map(calls, & &1.payload["new"]) == [1, 2]
    starts = EventCore.stream(core, 0, type: "run.started")

    assert Enum.count(starts, &(&1.payload["reason"] == "retry" and &1.payload["depth"] == 1)) ==
             1

    first_completion = hd(EventCore.stream(core, 0, type: "task.completed"))
    EventCore.redeliver(core, first_completion.event_id)
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "run.started")) == length(starts)
  end

  test "repeated parent correction has a durable limit and eventually breaks to human" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          if ctx.depth == 0 and ctx.reason == "initial",
            do: [delegate()],
            else: [report(false, "Still incomplete; continue using this comment")]
        end,
        1,
        1
      )

    EventCore.append!(
      core,
      Envelope.command("task.requested", work_item_id: "bounded", payload: %{instruction: "work"})
    )

    await(fn -> EventCore.stream(core, 0, type: "task.commented") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    starts = EventCore.stream(core, 0, type: "run.started")
    assert Enum.count(starts, &(&1.payload["reason"] == "break")) == 2
    assert Enum.count(starts, &(&1.payload["depth"] == 1)) == 4
  end

  test "technical failure breaks without automatically repeating a confirmed effect" do
    {core, _, runtime, _} =
      setup_runtime(fn _ ->
        [Fake.tool_call("counter", %{}), {:error, :provider_timeout}]
      end)

    EventCore.append!(
      core,
      Envelope.command("task.requested", work_item_id: "failure", payload: %{instruction: "work"})
    )

    await(fn -> EventCore.stream(core, 0, type: "task.break") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 1

    assert length(EventCore.stream(core, 0, type: "run.started")) == 1
  end

  test "persisted retry survives the gap before activation and replays identically" do
    {core, projector, _, opts} =
      setup_runtime(fn ctx ->
        assert ctx.reason == "retry"
        [report(true, "Recovered scheduled work")]
      end)

    stop_supervised!(Runtime)

    request =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: "scheduled",
          payload: %{instruction: "work"}
        )
      )

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          work_item_id: "scheduled",
          run_id: "old-run",
          causation_id: request.event_id,
          correlation_id: request.correlation_id,
          payload: %{
            attempt: 1,
            depth: 0,
            agent_id: "worker",
            agent_kind: "worker",
            reason: "initial",
            flow: %{"steps" => [], "root_approval" => "self"},
            stage: "to_do",
            max_retries: 1,
            tools: %{granted: ["counter"]},
            checkpoint: %{}
          }
        )
      )

    cp = %{
      messages: [%{role: "user", content: "Continue the confirmed work"}],
      tool_state: %{},
      awaiting: [],
      pending: %{}
    }

    closed =
      EventCore.append!(
        core,
        Envelope.event("run.completed",
          work_item_id: "scheduled",
          run_id: "old-run",
          causation_id: started.event_id,
          correlation_id: request.correlation_id,
          payload: %{
            outcome: "reported",
            report: %{completed: false, comment: "Continue"},
            max_retries: 1,
            comment: "Continue",
            checkpoint: cp
          }
        )
      )

    scheduled =
      EventCore.append!(
        core,
        Envelope.event("task.run_requested",
          causation_id: closed.event_id,
          work_item_id: "scheduled",
          correlation_id: request.correlation_id,
          payload: %{comment: "Continue", checkpoint: cp, reason: "retry", stage: "to_do"}
        )
      )

    runtime = start_supervised!({Runtime, Keyword.put(opts, :recover, true)})
    await(fn -> EventCore.stream(core, 0, type: "task.completed") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)

    assert Enum.count(
             EventCore.stream(core, 0, type: "run.started"),
             &(&1.causation_id == scheduled.event_id)
           ) == 1

    stop_supervised!(Runtime)
    Projector.sync(projector)
    before = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
    runtime = start_supervised!({Runtime, Keyword.put(opts, :recover, true)})
    assert Runtime.runs(runtime) == %{}
    EventCore.redeliver(core, scheduled.event_id)
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "run.started")) == 2
  end

  test "sibling breaks retain the parent's remaining dependencies" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.depth == 0 and ctx.reason == "initial" ->
              calls =
                for id <- ["a", "b"] do
                  hd(
                    Fake.tool_call(
                      "delegate",
                      %{"instruction" => id, "comment" => "Delegate #{id} and review its result"},
                      id
                    ).tool_calls
                  )
                end

              [%{content: nil, tool_calls: calls, usage: nil}]

            ctx.reason == "break" ->
              [report(true, "Verified target effect")]

            ctx.depth == 0 ->
              [report(true, "Both children reviewed")]

            true ->
              [
                Fake.tool_call("counter", %{}),
                report(false, "Effect recorded; parent should review", %{break: true})
              ]
          end
        end,
        1,
        0
      )

    assert {:ok, %{result: "Both children reviewed"}} =
             Runtime.request(core, "two tasks", timeout: 3000)

    await(fn -> Runtime.runs(runtime) == %{} end)
    assert length(EventCore.stream(core, 0, type: "task.completed")) == 3

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 2

    assert Enum.count(
             EventCore.stream(core, 0, type: "run.started"),
             &(&1.payload["reason"] == "break")
           ) == 2
  end

  test "explicit resume after a technical break closes the stale human request" do
    {core, projector, runtime, _} =
      setup_runtime(fn ctx ->
        if ctx.reason == "retry",
          do: [report(true, "Operator resumed and verified existing effect")],
          else: [Fake.tool_call("counter", %{}), {:error, :provider_timeout}]
      end)

    request =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: "resumed",
          payload: %{instruction: "work"}
        )
      )

    await(fn -> EventCore.stream(core, 0, type: "task.commented") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)

    assert {:ok, _} =
             Runtime.resume(core, "resumed",
               correlation_id: request.correlation_id,
               causation_id: request.event_id
             )

    await(fn -> EventCore.stream(core, 0, type: "task.assessment_resolved") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    Projector.sync(projector)

    assert [["completed"]] =
             EventCore.query(core, "SELECT status FROM WORK_ITEMS WHERE work_item_id = 'resumed'")

    assert [[0]] =
             EventCore.query(
               core,
               "SELECT count(*) FROM COMMENTS WHERE kind = 'request' AND read_at IS NULL"
             )

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 1
  end

  defp staged_config do
    config = Config.empty()

    %{
      config
      | workflows: %{
          "delivery" => %{
            "steps" => [
              %{"name" => "to_do", "instructions" => "Plan and record criteria"},
              %{"name" => "in_progress", "instructions" => "Implement the plan"},
              %{"name" => "verification", "instructions" => "Verify requested versus implemented"}
            ]
          }
        },
        agents: %{"worker" => %{workflow: "delivery"}}
    }
  end

  test "child report stays pending until the parent approves" do
    owner = self()

    {core, projector, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "assessment" ->
              [
                fn _ ->
                  send(owner, {:reviewing, self()})

                  receive do
                    :approve -> report(true, "Parent approved")
                  end
                end
              ]

            ctx.reason == "continuation" ->
              [report(true, "Root done")]

            ctx.depth == 0 ->
              [delegate()]

            true ->
              [report(true, "Child claims done")]
          end
        end,
        1
      )

    task = Task.async(fn -> Runtime.request(core, "work", timeout: 3000) end)
    assert_receive {:reviewing, reviewer}, 2000
    assert EventCore.stream(core, 0, type: "task.completed") == []
    Projector.sync(projector)

    assert [["to_do", "waiting"]] =
             EventCore.query(
               core,
               "SELECT status, state FROM WORK_ITEMS WHERE parent_work_item_id IS NOT NULL"
             )

    send(reviewer, :approve)
    assert {:ok, %{result: "Root done"}} = Task.await(task)
    await(fn -> Runtime.runs(runtime) == %{} end)
    [child, _root] = EventCore.stream(core, 0, type: "task.completed")
    [review] = EventCore.stream(core, 0, type: "task.assessment_requested")
    assert child.sequence > review.sequence
    assert child.payload["comment"] == "Parent approved"
  end

  test "parent approvals advance each child stage once and complete only the last" do
    {core, projector, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "assessment" ->
              [report(true, "Approved #{ctx.assessment["stage"]}")]

            ctx.reason == "continuation" ->
              [report(true, "Delivered")]

            ctx.depth == 0 ->
              [delegate()]

            true ->
              [Fake.tool_call("counter", %{}), report(true, "Stage #{ctx.stage} effect recorded")]
          end
        end,
        1,
        0,
        staged_config()
      )

    assert {:ok, %{result: "Delivered"}} = Runtime.request(core, "delivery", timeout: 3000)
    await(fn -> Runtime.runs(runtime) == %{} end)
    advances = EventCore.stream(core, 0, type: "task.advanced")

    assert Enum.map(advances, &{&1.payload["from"], &1.payload["to"]}) == [
             {"to_do", "in_progress"},
             {"in_progress", "verification"}
           ]

    assert length(EventCore.stream(core, 0, type: "task.assessment_requested")) == 3
    assert length(EventCore.stream(core, 0, type: "task.completed")) == 2

    assert Enum.map(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter")),
             & &1.payload["new"]
           ) ==
             [1, 2, 3]

    for event <- advances, do: EventCore.redeliver(core, event.event_id)
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "task.advanced")) == 2
    Projector.sync(projector)

    assert [["completed", "idle"], ["completed", "idle"]] =
             EventCore.query(core, "SELECT status, state FROM WORK_ITEMS")

    before = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
  end

  test "root stages have independent retry budgets and fresh step contexts" do
    owner = self()

    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          if ctx.reason == "retry" do
            [report(true, "Stage approved after correction")]
          else
            [
              fn messages ->
                send(owner, {:stage_context, ctx.stage, messages})
                report(false, "Correct only this stage")
              end
            ]
          end
        end,
        0,
        1,
        staged_config()
      )

    assert {:ok, _} = Runtime.request(core, "delivery", timeout: 3000)
    await(fn -> Runtime.runs(runtime) == %{} end)
    starts = EventCore.stream(core, 0, type: "run.started")

    assert Enum.map(starts, & &1.payload["reason"]) == [
             "initial",
             "retry",
             "step",
             "retry",
             "step",
             "retry"
           ]

    assert EventCore.stream(core, 0, type: "task.break") == []

    for stage <- ["to_do", "in_progress", "verification"] do
      assert_receive {:stage_context, ^stage, messages}
      assert hd(messages)["content"] =~ "Work stage: #{stage}"
      refute Enum.any?(messages, &(&1["role"] == "assistant"))
    end
  end

  test "failed child retains its logical status while the parent inspects effects" do
    owner = self()

    {core, projector, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "break" ->
              [
                fn _ ->
                  send(owner, {:failure_review, self()})

                  receive do
                    :approve -> report(true, "Existing effect verified")
                  end
                end
              ]

            ctx.reason == "continuation" ->
              [report(true, "Done")]

            ctx.depth == 0 ->
              [delegate()]

            true ->
              [Fake.tool_call("counter", %{}), {:error, :timeout}]
          end
        end,
        1
      )

    task = Task.async(fn -> Runtime.request(core, "work", timeout: 3000) end)
    assert_receive {:failure_review, reviewer}, 2000
    Projector.sync(projector)

    assert [["to_do", "failed"]] =
             EventCore.query(
               core,
               "SELECT status, state FROM WORK_ITEMS WHERE parent_work_item_id IS NOT NULL"
             )

    send(reviewer, :approve)
    assert {:ok, _} = Task.await(task)
    await(fn -> Runtime.runs(runtime) == %{} end)

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 1
  end

  test "human root approval is configurable and does not rerun the executor" do
    config = Config.empty()
    config = %{config | defaults: Map.put(config.defaults, :root_approval, "human")}

    {core, _, runtime, _} =
      setup_runtime(fn _ -> [report(true, "Ready for user review")] end, 0, 1, config)

    task = Task.async(fn -> Runtime.request(core, "work", timeout: 3000) end)
    await(fn -> EventCore.stream(core, 0, type: "task.commented") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    assert EventCore.stream(core, 0, type: "task.completed") == []
    [request] = EventCore.stream(core, 0, type: "task.commented")

    EventCore.append!(
      core,
      Envelope.command("task.commented",
        work_item_id: request.work_item_id,
        correlation_id: request.correlation_id,
        payload: %{
          kind: "response",
          request_id: request.payload["request_id"],
          body: Jason.encode!(%{completed: true, comment: "User verified"})
        }
      )
    )

    assert {:ok, %{result: "User verified"}} = Task.await(task)
    assert length(EventCore.stream(core, 0, type: "run.started")) == 1
  end

  test "restart after stage approval schedules the next stage without approving it twice" do
    config = staged_config()

    {core, projector, _, opts} =
      setup_runtime(
        fn ctx ->
          assert ctx.reason == "step"
          [report(true, "Approved #{ctx.stage}")]
        end,
        0,
        0,
        config
      )

    stop_supervised!(Runtime)

    request =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: "gap",
          payload: %{instruction: "delivery"}
        )
      )

    flow = Config.workflow(config, config.agents["worker"], %{})

    started =
      EventCore.append!(
        core,
        Envelope.event("run.started",
          work_item_id: "gap",
          run_id: "first",
          correlation_id: request.correlation_id,
          causation_id: request.event_id,
          payload: %{
            attempt: 1,
            depth: 0,
            agent_id: "worker",
            agent_kind: "worker",
            reason: "initial",
            flow: flow,
            stage: "to_do",
            max_retries: 0,
            tools: %{granted: []},
            checkpoint: %{}
          }
        )
      )

    closed =
      EventCore.append!(
        core,
        Envelope.event("run.completed",
          work_item_id: "gap",
          run_id: "first",
          correlation_id: request.correlation_id,
          causation_id: started.event_id,
          payload: %{
            outcome: "reported",
            report: %{completed: true, comment: "Plan approved"},
            comment: "Plan approved",
            checkpoint: %{},
            max_retries: 0
          }
        )
      )

    EventCore.append!(
      core,
      Envelope.event("task.advanced",
        work_item_id: "gap",
        correlation_id: request.correlation_id,
        causation_id: closed.event_id,
        payload: %{from: "to_do", to: "in_progress", comment: "Plan approved", checkpoint: %{}}
      )
    )

    runtime = start_supervised!({Runtime, Keyword.put(opts, :recover, true)})
    await(fn -> EventCore.stream(core, 0, type: "task.completed") != [] end)
    await(fn -> Runtime.runs(runtime) == %{} end)
    assert length(EventCore.stream(core, 0, type: "task.advanced")) == 2
    assert length(EventCore.stream(core, 0, type: "run.started")) == 3
    stop_supervised!(Runtime)
    Projector.sync(projector)
    before = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
    runtime = start_supervised!({Runtime, Keyword.put(opts, :recover, true)})
    assert Runtime.runs(runtime) == %{}
    assert length(EventCore.stream(core, 0, type: "run.started")) == 3
  end

  test "an old review cannot approve a newer execution of the same stage" do
    owner = self()

    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "break" ->
              [
                fn _ ->
                  send(owner, {:old_review, self()})

                  receive do
                    :approve -> report(true, "Old approval")
                  end
                end
              ]

            ctx.reason == "assessment" ->
              [report(true, "Current execution approved")]

            ctx.reason == "continuation" ->
              [report(true, "Done")]

            ctx.depth == 0 ->
              [delegate()]

            ctx.reason == "retry" ->
              [
                fn _ ->
                  send(owner, {:new_execution, self()})

                  receive do
                    :finish -> report(true, "New report")
                  end
                end
              ]

            true ->
              [{:error, :timeout}]
          end
        end,
        1
      )

    task = Task.async(fn -> Runtime.request(core, "work", timeout: 3000) end)
    assert_receive {:old_review, reviewer}, 2000
    [failed] = EventCore.stream(core, 0, type: "run.failed")

    EventCore.append!(
      core,
      Envelope.command("task.resumed",
        work_item_id: failed.work_item_id,
        correlation_id: failed.correlation_id,
        causation_id: failed.event_id,
        payload: %{}
      )
    )

    assert_receive {:new_execution, executor}, 2000
    send(reviewer, :approve)
    await(fn -> EventCore.stream(core, 0, type: "task.assessment_resolved") != [] end)
    assert EventCore.stream(core, 0, type: "task.completed") == []
    send(executor, :finish)
    assert {:ok, _} = Task.await(task)
    await(fn -> Runtime.runs(runtime) == %{} end)
    [child, _root] = EventCore.stream(core, 0, type: "task.completed")
    assert child.payload["comment"] == "Current execution approved"
  end

  test "reviewer role starts only at the configured review gate" do
    owner = self()
    config = staged_config()

    config = %{
      config
      | workflows: %{
          "delivery" => %{
            "steps" => [
              %{"name" => "in_progress", "instructions" => "Implement once"},
              %{
                "name" => "review",
                "agent" => "reviewer",
                "instructions" => "Review existing effects"
              }
            ]
          }
        }
    }

    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.reason == "assessment" ->
              [report(true, "Parent approved #{ctx.assessment["stage"]}")]

            ctx.reason == "continuation" ->
              [report(true, "Delivery complete")]

            ctx.depth == 0 ->
              [delegate()]

            ctx.reason == "initial" ->
              [Fake.tool_call("counter", %{}), report(true, "One effect exists")]

            ctx.stage == "review" ->
              [
                fn messages ->
                  send(owner, {:gate_context, messages})
                  report(true, "Gate verified existing effect")
                end
              ]
          end
        end,
        1,
        0,
        config
      )

    assert {:ok, %{result: "Delivery complete"}} =
             Runtime.request(core, "delivery", timeout: 3000)

    await(fn -> Runtime.runs(runtime) == %{} end)
    starts = EventCore.stream(core, 0, type: "run.started")

    assert [%{payload: %{"stage" => "review", "reason" => "step", "depth" => 1}}] =
             Enum.filter(starts, &(&1.payload["agent_kind"] == "reviewer"))

    assert Enum.all?(
             Enum.filter(starts, &(&1.payload["reason"] == "assessment")),
             &(&1.payload["agent_kind"] == "concierge" and &1.payload["depth"] == 0)
           )

    assert length(
             EventCore.stream(core, 0, type: "tool.call.completed")
             |> Enum.filter(&(&1.payload["tool"] == "counter"))
           ) == 1

    assert_receive {:gate_context, messages}
    assert hd(messages)["content"] =~ "Kind: reviewer"
    assert hd(messages)["content"] =~ "Work stage: review"
    refute Enum.any?(messages, &(&1["role"] == "assistant"))
  end

  test "parent can delegate during assessment and resume its original target" do
    {core, _, runtime, _} =
      setup_runtime(
        fn ctx ->
          cond do
            ctx.depth == 1 ->
              [report(true, "Evidence checked")]

            ctx.reason == "initial" ->
              [delegate()]

            ctx.reason == "continuation" ->
              [report(true, "Root complete")]

            ctx.reason == "assessment" and ctx.instruction =~ "Target task: produce evidence" ->
              [
                Fake.tool_call("delegate", %{
                  "instruction" => "Check existing evidence",
                  "comment" => "Obtain independent verification"
                })
              ]

            ctx.reason == "assessment" ->
              [report(true, "Approved after verification")]
          end
        end,
        1
      )

    result = Runtime.request(core, "deliver", timeout: 3000)
    assert {:ok, %{result: "Root complete"}} = result
    await(fn -> Runtime.runs(runtime) == %{} end)
    assert length(EventCore.stream(core, 0, type: "task.delegated")) == 2
    assert length(EventCore.stream(core, 0, type: "task.completed")) == 3

    assert Enum.all?(
             EventCore.query(core, "SELECT status FROM WORK_ITEMS"),
             &(&1 == ["completed"])
           )
  end

  test "unknown selectors are rejected before creating a child" do
    {core, _, _, _} =
      setup_runtime(
        fn ctx ->
          if ctx.depth == 0 do
            [
              Fake.tool_call("delegate", %{
                "agent" => "invented",
                "instruction" => "work",
                "comment" => "check"
              }),
              Fake.tool_call("delegate", %{
                "team" => "invented-team",
                "instruction" => "work",
                "comment" => "check"
              }),
              report(true, "No child authorized")
            ]
          else
            flunk("unknown selector was executed")
          end
        end,
        1
      )

    assert {:ok, _} = Runtime.request(core, "check selectors", timeout: 3000)
    assert length(EventCore.stream(core, 0, type: "delivery.rejected")) == 2
    assert [[1]] = EventCore.query(core, "SELECT count(*) FROM WORK_ITEMS")
  end
end
