defmodule Omunculus.InterceptionTest do
  use ExUnit.Case, async: true
  alias Omunculus.{EventCore, Config, Runtime, Chat}
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Projector

  defp rule(extra \\ %{}) do
    Map.merge(
      %{
        name: "context",
        events: ["run.completed"],
        actor: "external:context",
        agent: nil,
        module: nil,
        enabled: true,
        wait: true,
        max_retries: 1,
        match: %{"outcome" => "reported"},
        workspaces: nil,
        work_item: %{"instruction" => "Process this event"},
        response: %{"comment" => "string"},
        bindings: %{"report.comment" => "comment"}
      },
      extra
    )
  end

  defp source(core) do
    EventCore.append!(
      core,
      Envelope.event("run.completed",
        causation_id: "event-source",
        session_id: "session-test",
        work_item_id: "wi-source",
        run_id: "run-source",
        payload: %{outcome: "reported", report: %{completed: false, comment: "original"}}
      )
    )
  end

  defp reply(core, req, fields) do
    EventCore.append(
      core,
      Envelope.command("interception.responded",
        correlation_id: req.correlation_id,
        session_id: req.session_id,
        causation_id: req.event_id,
        payload: Map.merge(%{request_id: req.event_id, actor: req.payload["actor"]}, fields)
      )
    )
  end

  test "external actor gates delivery without blocking the Core or changing the source" do
    core = start_supervised!({EventCore, path: ":memory:", interceptors: [rule()]})
    EventCore.subscribe(core)
    source = source(core)
    id = source.event_id
    assert_receive {:event_core, %{type: "interception.requested"} = req}
    refute_receive {:event_core, %{event_id: ^id}}, 20
    assert EventCore.delivery(core, source) == :pending
    assert EventCore.delivered_stream(core, 0, type: "run.completed") == []

    other =
      EventCore.append!(
        core,
        Envelope.event("model.call.completed",
          causation_id: "model-request",
          payload: %{round: 1, outcome: "final_response"}
        )
      )

    other_id = other.event_id
    assert_receive {:event_core, %{event_id: ^other_id}}

    assert {:error, :invalid_interception_output} =
             reply(core, req, %{outcome: "completed", output: %{comment: ""}})

    assert {:error, :interception_actor_mismatch} =
             reply(core, req, %{actor: "wrong", outcome: "completed", output: %{comment: "new"}})

    assert {:ok, response} =
             reply(core, req, %{outcome: "completed", output: %{comment: "new context"}})

    assert_receive {:event_core,
                    %{event_id: ^id, payload: %{"report" => %{"comment" => "original"}}}}

    assert {:ready, delivered} = EventCore.delivery(core, source)
    assert delivered.payload["report"] == %{"completed" => false, "comment" => "new context"}
    assert {:ok, ^source} = EventCore.fetch(core, id)
    assert {:ok, ^response} = EventCore.append(core, response)

    assert {:error, :interception_already_answered} =
             reply(core, req, %{outcome: "completed", output: %{comment: "duplicate"}})

    assert length(EventCore.stream(core, 0, type: "interception.resolved")) == 1
  end

  test "retry budget is durable and exhaustion requests human intervention" do
    core = start_supervised!({EventCore, path: ":memory:", interceptors: [rule()]})
    original = source(core)
    [first] = EventCore.stream(core, 0, type: "interception.requested")
    assert {:ok, _} = reply(core, first, %{outcome: "failed", error: "actor unavailable"})
    [_, retry] = EventCore.stream(core, 0, type: "interception.requested")
    assert retry.payload["attempt"] == 1
    assert {:ok, _} = reply(core, retry, %{outcome: "failed", error: "failed again"})
    [_, _, human] = EventCore.stream(core, 0, type: "interception.requested")
    assert human.payload["actor"] == "human"
    assert human.payload["attempt"] == 2
    assert EventCore.delivery(core, original) == :pending

    assert {:ok, _} =
             reply(core, human, %{outcome: "completed", output: %{comment: "human context"}})

    assert {:ready, effective} = EventCore.delivery(core, original)
    assert effective.payload["report"]["comment"] == "human context"
  end

  test "pending requests and their config snapshot survive Core restart" do
    dir = Path.join(System.tmp_dir!(), "interception-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "events.sqlite3")
    {:ok, first} = EventCore.start_link(path: path, interceptors: [rule()])
    original = source(first)
    [req] = EventCore.stream(first, 0, type: "interception.requested")
    GenServer.stop(first)
    {:ok, second} = EventCore.start_link(path: path)
    assert EventCore.delivery(second, original) == :pending

    assert {:ok, _} =
             reply(second, req, %{outcome: "completed", output: %{comment: "after restart"}})

    GenServer.stop(second)
    {:ok, third} = EventCore.start_link(path: path)
    assert {:ready, effective} = EventCore.delivery(third, original)
    assert effective.payload["report"]["comment"] == "after restart"
    assert length(EventCore.stream(third, 0, type: "interception.requested")) == 1
    assert length(EventCore.stream(third, 0, type: "interception.resolved")) == 1
    GenServer.stop(third)
  end

  test "disabled interceptor preserves ordinary events and creates no request" do
    core =
      start_supervised!({EventCore, path: ":memory:", interceptors: [rule(%{enabled: false})]})

    EventCore.subscribe(core)
    original = source(core)
    id = original.event_id
    assert_receive {:event_core, %{event_id: ^id}}
    assert EventCore.stream(core, 0, type: "interception.requested") == []
    assert EventCore.delivery(core, original) == {:ready, original}
  end

  test "nonblocking actor observes while delivery continues" do
    core =
      start_supervised!(
        {EventCore, path: ":memory:", interceptors: [rule(%{wait: false, bindings: %{}})]}
      )

    EventCore.subscribe(core)
    original = source(core)
    id = original.event_id
    assert_receive {:event_core, %{event_id: ^id}}
    assert [_] = EventCore.stream(core, 0, type: "interception.requested")
    assert EventCore.delivery(core, original) == {:ready, original}
  end

  test "response deadline escalates by protocol and a late reply cannot resume it" do
    core =
      start_supervised!(
        {EventCore, path: ":memory:", interceptors: [rule(%{max_retries: 0, timeout_ms: 20})]}
      )

    EventCore.subscribe(core)
    source = source(core)
    assert_receive {:event_core, %{type: "interception.requested"} = request}
    assert_receive {:event_core, %{type: "interception.expired"}}, 2000

    assert_receive {:event_core,
                    %{type: "interception.requested", payload: %{"actor" => "human"}} = human}

    assert EventCore.delivery(core, source) == :pending

    assert {:error, :interception_already_answered} =
             reply(core, request, %{outcome: "completed", output: %{comment: "late"}})

    assert is_nil(human.payload["deadline_at"])
    assert {:ok, _} = reply(core, human, %{outcome: "completed", output: %{comment: "resolved"}})
  end

  test "multiple actors can reply out of order but binding order remains configured" do
    core =
      start_supervised!(
        {EventCore,
         path: ":memory:",
         interceptors: [rule(), rule(%{name: "second", actor: "external:second"})]}
      )

    source = source(core)
    [first, second] = EventCore.stream(core, 0, type: "interception.requested")
    assert {:ok, _} = reply(core, second, %{outcome: "completed", output: %{comment: "second"}})
    assert EventCore.delivery(core, source) == :pending
    assert {:ok, _} = reply(core, first, %{outcome: "completed", output: %{comment: "first"}})
    assert {:ready, effective} = EventCore.delivery(core, source)
    assert effective.payload["report"]["comment"] == "second"
  end

  test "retry snapshot and deadline survive Core restart without duplicate requests" do
    dir = Path.join(System.tmp_dir!(), "interception-crash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "events.sqlite3")
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule(%{timeout_ms: 60000})])
    source = source(core)
    [request] = EventCore.stream(core, 0, type: "interception.requested")
    {:ok, _} = reply(core, request, %{outcome: "failed", error: "first failure"})
    requests = EventCore.stream(core, 0, type: "interception.requested")
    GenServer.stop(core)
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    # The retry deadline and rule snapshot are replayed, not regenerated from the clock.
    assert EventCore.stream(core, 0, type: "interception.requested") == requests
    assert EventCore.delivery(core, source) == :pending
    GenServer.stop(core)
  end

  test "recovery reconstructs a dependency after source commit before dispatch" do
    dir = Path.join(System.tmp_dir!(), "interception-gap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "events.sqlite3")
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    source = source(core)
    # Reconstruct the durable state of a crash between append and dispatch.
    EventCore.transaction(core, fn conn ->
      Omunculus.EventCore.Store.query(
        conn,
        "DELETE FROM EVENTS WHERE type = 'interception.requested'"
      )

      Omunculus.EventCore.Store.query(
        conn,
        "UPDATE PROJECTION_CURSORS SET last_sequence = ? WHERE projection = 'actor-delivery'",
        [source.sequence - 1]
      )
    end)

    GenServer.stop(core)
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    assert EventCore.delivery(core, source) == :pending
    assert [_] = EventCore.stream(core, 0, type: "interception.requested")
    GenServer.stop(core)
  end

  test "recovery completes a committed response without a resolution event" do
    dir =
      Path.join(System.tmp_dir!(), "interception-reply-gap-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "events.sqlite3")
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    source = source(core)
    [request] = EventCore.stream(core, 0, type: "interception.requested")

    {:ok, response} =
      reply(core, request, %{outcome: "completed", output: %{comment: "recovered context"}})

    EventCore.transaction(core, fn conn ->
      Omunculus.EventCore.Store.query(
        conn,
        "DELETE FROM EVENTS WHERE type = 'interception.resolved'"
      )

      Omunculus.EventCore.Store.query(
        conn,
        "UPDATE PROJECTION_CURSORS SET last_sequence = ? WHERE projection = 'actor-delivery'",
        [response.sequence - 1]
      )
    end)

    GenServer.stop(core)
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    assert {:ready, effective} = EventCore.delivery(core, source)
    assert effective.payload["report"]["comment"] == "recovered context"
    assert [_] = EventCore.stream(core, 0, type: "interception.resolved")
    GenServer.stop(core)
  end

  test "runtime recovery does not rerun a closed executor awaiting an external actor" do
    core = start_supervised!({EventCore, path: ":memory:", interceptors: [rule()]})
    start_supervised!({Projector, core: core})
    EventCore.subscribe(core)
    owner = self()

    resolver = fn ctx ->
      chat =
        Chat.Fake.new([
          fn _ ->
            send(owner, :executed)
            Chat.Fake.report("original")
          end
        ])
        |> Map.put(:model, "test")

      Omunculus.Runtime.Agents.resolve(ctx, %{chat: chat})
    end

    {:ok, runtime} = Runtime.start_link(core: core, max_depth: 0, agents: resolver)

    root =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          session_id: "session-test",
          work_item_id: "wi-restart",
          payload: %{instruction: "Work"}
        )
      )

    assert_receive :executed
    assert_receive {:event_core, %{type: "interception.requested"} = request}, 1000
    GenServer.stop(runtime)
    {:ok, runtime} = Runtime.start_link(core: core, max_depth: 0, agents: resolver, recover: true)
    refute_receive :executed, 30
    assert EventCore.stream(core, 0, type: "run.failed") == []
    assert EventCore.stream(core, 0, type: "task.completed") == []

    assert {:ok, _} =
             reply(core, request, %{outcome: "completed", output: %{comment: "after restart"}})

    wi = root.work_item_id

    assert_receive {:event_core,
                    %{
                      type: "task.completed",
                      work_item_id: ^wi,
                      payload: %{"result" => "after restart"}
                    }},
                   1000

    assert length(EventCore.stream(core, 0, type: "run.started")) == 1
    GenServer.stop(runtime)
  end

  test "external emit port correlates a response and the resident owner releases delivery" do
    dir = Path.join(System.tmp_dir!(), "interception-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "events.sqlite3")
    {:ok, core} = EventCore.start_link(path: path, interceptors: [rule()])
    EventCore.subscribe(core)
    original = source(core)
    [request] = EventCore.stream(core, 0, type: "interception.requested")

    payload =
      Jason.encode!(%{
        actor: request.payload["actor"],
        outcome: "completed",
        output: %{comment: "external process context"}
      })

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Omunculus.CLI.dispatch(
                 [
                   "emit",
                   "interception.responded",
                   "--db",
                   path,
                   "--request-id",
                   request.event_id,
                   "--payload",
                   payload
                 ],
                 %{}
               ) == 0
      end)

    emitted = Jason.decode!(String.trim(output))
    assert emitted["correlation_id"] == original.correlation_id
    assert emitted["session_id"] == original.session_id
    EventCore.poll(core)
    id = original.event_id
    assert_receive {:event_core, %{event_id: ^id}}
    assert {:ready, effective} = EventCore.delivery(core, original)
    assert effective.payload["report"]["comment"] == "external process context"
    GenServer.stop(core)
  end

  test "delegating Run closes while the child activation awaits an external actor" do
    gate = rule(%{events: ["task.delegated"], match: %{}, bindings: %{"comment" => "comment"}})
    core = start_supervised!({EventCore, path: ":memory:", interceptors: [gate]})
    start_supervised!({Projector, core: core})
    EventCore.subscribe(core)

    resolver = fn ctx ->
      script =
        cond do
          ctx.depth == 1 ->
            [Chat.Fake.report("child done")]

          ctx.reason == "initial" ->
            [
              Chat.Fake.tool_call("delegate", %{
                "work_item" => %{"instruction" => "Child task"},
                "comment" => "original handoff"
              })
            ]

          true ->
            [Chat.Fake.report("approved")]
        end

      Omunculus.Runtime.Agents.resolve(ctx, %{
        chat: Chat.Fake.new(script) |> Map.put(:model, "test")
      })
    end

    runtime = start_supervised!({Runtime, core: core, max_depth: 1, agents: resolver})

    root =
      EventCore.append!(
        core,
        Envelope.command("task.requested",
          work_item_id: "wi-delegator",
          payload: %{instruction: "Delegate"}
        )
      )

    assert_receive {:event_core, %{type: "interception.requested"} = request}, 1000

    assert_receive {:event_core, %{type: "run.completed", payload: %{"outcome" => "waiting"}}},
                   1000

    assert length(EventCore.stream(core, 0, type: "run.started")) == 1

    assert {:ok, _} =
             reply(core, request, %{outcome: "completed", output: %{comment: "ready context"}})

    wi = root.work_item_id
    assert_receive {:event_core, %{type: "task.completed", work_item_id: ^wi}}, 1000

    child =
      EventCore.stream(core, 0, type: "run.started") |> Enum.find(&(&1.payload["depth"] == 1))

    assert child.payload["comment"] == "ready context"
    [resolution] = EventCore.stream(core, 0, type: "interception.resolved")
    assert child.sequence > resolution.sequence
    GenServer.stop(runtime)
  end

  for boundary <- ["task.run_requested", "task.advanced"] do
    test "#{boundary} delivers the replaced comment into the next checkpoint" do
      boundary = unquote(boundary)

      dir =
        Path.join(
          System.tmp_dir!(),
          "interception-checkpoint-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      if boundary == "task.advanced" do
        File.write!(Path.join(dir, "omunculus.toml"), """
        [defaults]
        workflow = "delivery"
        [workflows.delivery]
        steps = [{name = "implement", instructions = "Perform work"}, {name = "review", instructions = "Review work"}]
        """)
      end

      gate = rule(%{events: [boundary], match: %{}, bindings: %{"comment" => "comment"}})
      core = start_supervised!({EventCore, path: ":memory:", interceptors: [gate]})
      start_supervised!({Projector, core: core})
      EventCore.subscribe(core)
      owner = self()

      resolver = fn ctx ->
        script =
          if ctx.reason == "initial" do
            [
              Chat.Fake.text(
                Jason.encode!(%{completed: boundary == "task.advanced", comment: "old context"})
              )
            ]
          else
            [
              fn messages ->
                send(owner, {:next_input, messages})
                Chat.Fake.report("done")
              end
            ]
          end

        Omunculus.Runtime.Agents.resolve(ctx, %{
          chat: Chat.Fake.new(script) |> Map.put(:model, "test")
        })
      end

      runtime =
        start_supervised!(
          {Runtime, core: core, max_depth: 0, agents: resolver, config: [cwd: dir]}
        )

      root =
        EventCore.append!(
          core,
          Envelope.command("task.requested",
            work_item_id: "wi-checkpoint",
            payload: %{instruction: "Work"}
          )
        )

      assert_receive {:event_core, %{type: "interception.requested"} = request}, 1000

      assert {:ok, _} =
               reply(core, request, %{
                 outcome: "completed",
                 output: %{comment: "replacement context"}
               })

      assert_receive {:next_input, messages}, 1000
      assert List.last(messages)["content"] =~ "replacement context"
      wi = root.work_item_id
      assert_receive {:event_core, %{type: "task.completed", work_item_id: ^wi}}, 1000
      GenServer.stop(runtime)
    end
  end

  test "agent response schema accepts boolean data without task completion semantics" do
    dir =
      Path.join(System.tmp_dir!(), "interception-schema-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "omunculus.toml"), """
    [interceptors.context]
    events = ["run.completed"]
    agent = "summarizer"
    work_item = {instruction = "Describe the evidence"}
    response = {comment = "string", observed = "boolean"}
    bindings = {"comment" = "comment"}
    """)

    {:ok, config} = Config.load(cwd: dir, env: %{})
    assert {:ok, checked} = Config.check(config)
    core = start_supervised!({EventCore, path: ":memory:", interceptors: checked.interceptors})
    start_supervised!({Projector, core: core})
    EventCore.subscribe(core)

    resolver = fn ctx ->
      Omunculus.Runtime.Agents.resolve(ctx, %{
        chat:
          Chat.Fake.new([
            Chat.Fake.text(Jason.encode!(%{comment: "The source task failed", observed: false}))
          ])
          |> Map.put(:model, "test")
      })
    end

    start_supervised!({Runtime, core: core, agents: resolver, config: [cwd: dir]})
    original = source(core)
    assert_receive {:event_core, %{type: "interception.resolved"}}, 2000
    assert {:ready, delivered} = EventCore.delivery(core, original)
    assert delivered.payload["comment"] == "The source task failed"
    assert delivered.payload["report"]["completed"] == false
    [response] = EventCore.stream(core, 0, type: "interception.responded")
    assert response.payload["output"]["observed"] == false
    assert response.payload["outcome"] == "completed"
  end

  for failure? <- [false, true], filtered? <- [false, true], source_completed? <- [false, true] do
    test "configured agent produces context with initial failure=#{failure?}, filtered=#{filtered?}, source_completed=#{source_completed?}" do
      source_completed? = unquote(source_completed?)
      failure? = unquote(failure?)
      filtered? = unquote(filtered?)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      dir =
        Path.join(System.tmp_dir!(), "interception-agent-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "omunculus.toml"), """
      [agents.summarizer]
      prompt = "Summarize the supplied event and its execution evidence."
      tools = []
      workflow = false
      [interceptors.context]
      events = ["run.completed"]
      agent = "summarizer"
      match = {"report.comment" = "executor raw"}
      work_item = {instruction = "Produce the handoff context"}
      response = {comment = "string"}
      bindings = {"report.comment" = "comment"}
      #{if filtered?, do: ~s(exclude = ["payload.comment", "payload.report"]\nexclude_items = [{path = "payload.checkpoint.messages", match = {role = "assistant"}, missing = ["tool_calls"]}]), else: ""}
      """)

      {:ok, config} = Config.load(cwd: dir, env: %{})
      assert {:ok, checked} = Config.check(config)
      core = start_supervised!({EventCore, path: ":memory:", interceptors: checked.interceptors})
      projector = start_supervised!({Projector, core: core})
      owner = self()

      resolver = fn ctx ->
        script =
          cond do
            ctx.agent == "summarizer" ->
              [
                fn messages ->
                  send(owner, {:actor_input, messages})
                  attempt = Agent.get_and_update(calls, &{&1, &1 + 1})

                  if failure? and attempt == 0,
                    do:
                      Chat.Fake.text(
                        Jason.encode!(%{
                          completed: false,
                          break: true,
                          comment: "Processing failed"
                        })
                      ),
                    else:
                      Chat.Fake.text(
                        Jason.encode!(%{comment: "compact evidence: counter returned 1"})
                      )
                end
              ]

            ctx.depth == 1 ->
              [
                Chat.Fake.tool_call("counter", %{}),
                Chat.Fake.report("executor raw", source_completed?)
              ]

            ctx.reason == "initial" ->
              [
                Chat.Fake.tool_call("delegate", %{
                  "work_item" => %{"instruction" => "Increment once"},
                  "comment" => "handoff"
                })
              ]

            true ->
              [
                fn messages ->
                  send(owner, {:parent_input, messages})
                  Chat.Fake.report("approved")
                end
              ]
          end

        Omunculus.Runtime.Agents.resolve(ctx, %{
          chat: Chat.Fake.new(script) |> Map.put(:model, "test")
        })
      end

      runtime =
        start_supervised!(
          {Runtime, core: core, max_depth: 1, agents: resolver, config: [cwd: dir]}
        )

      assert {:ok, %{result: "approved"}} =
               Runtime.request(core, "Delegate one increment", timeout: 5000)

      assert_receive {:actor_input, messages}
      assert hd(messages)["content"] =~ "Summarize the supplied event"
      refute hd(messages)["content"] =~ "When returning your final report"

      assert Enum.any?(messages, &String.contains?(&1["content"] || "", "executor raw")) ==
               not filtered?

      assert Enum.any?(messages, &String.contains?(&1["content"] || "", "Counter value: 1"))
      assert_receive {:parent_input, parent_messages}
      refute Enum.any?(parent_messages, &String.contains?(&1["content"] || "", "executor raw"))

      assert Enum.any?(
               parent_messages,
               &String.contains?(&1["content"] || "", "compact evidence: counter returned 1")
             )

      requests = EventCore.stream(core, 0, type: "interception.requested")
      assert length(requests) == if(failure?, do: 2, else: 1)

      refute Enum.any?(
               EventCore.stream(core, 0, type: "task.commented"),
               &(&1.payload["assessment"] == true)
             )

      actor_ids = Enum.map(requests, & &1.payload["actor_work_item_id"])

      refute Enum.any?(EventCore.stream(core, 0), fn e ->
               e.work_item_id in actor_ids and
                 e.type in ["task.break", "task.recovery_used", "task.assessment_requested"]
             end)

      assert Agent.get(calls, & &1) == length(requests)
      request = List.last(requests)
      actor_wi = request.payload["actor_work_item_id"]

      assert [%{payload: %{"agent_id" => "summarizer", "available_tools" => []}}] =
               EventCore.stream(core, 0, type: "run.started", work_item_id: actor_wi)

      assert [_] = EventCore.stream(core, 0, type: "interception.resolved")

      [response] =
        Enum.filter(
          EventCore.stream(core, 0, type: "interception.responded"),
          &(&1.payload["outcome"] == "completed")
        )

      assert response.payload["output"] == %{"comment" => "compact evidence: counter returned 1"}
      {:ok, original} = EventCore.fetch(core, request.payload["source_event_id"])
      assert original.payload["report"]["completed"] == source_completed?

      GenServer.stop(runtime)
      Projector.sync(projector)
      before = Projector.snapshot(core)
      Projector.rebuild(projector)
      assert Projector.snapshot(core) == before
    end
  end
end
