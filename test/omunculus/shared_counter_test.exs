defmodule Omunculus.SharedCounterTest do
  use ExUnit.Case, async: true
  alias Omunculus.{EventCore, Runtime, Tools, Chat.Fake}
  alias Omunculus.Tool.Context
  alias Omunculus.EventCore.Projector

  test "a resource is atomic across contexts and isolated from other sessions" do
    {:ok, resource} = Agent.start_link(fn -> %{value: 4, calls: 0} end)
    {:ok, other} = Agent.start_link(fn -> %{value: 0, calls: 0} end)

    ctx = fn pid ->
      Context.new(Omunculus.FS.Memory.new(), %{tools: %{"counter" => %{resource: pid}}})
    end

    1..20
    |> Task.async_stream(fn _ -> Tools.Counter.call(%{}, ctx.(resource)) end)
    |> Enum.to_list()

    assert Agent.get(resource, & &1.value) == 24
    assert {:ok, "Counter value: 23", _} = Tools.CounterDecrement.call(%{}, ctx.(resource))
    assert {:ok, "Counter value: 1", _} = Tools.Counter.call(%{}, ctx.(other))
    assert {:error, :invalid_arguments, _} = Tools.Counter.call(%{"count" => 3}, ctx.(resource))
    assert Agent.get(resource, & &1.calls) == 21

    assert {:error, :denied, _} =
             Tools.call_context("counter_decrement", %{}, ctx.(resource), ["counter"])
  end

  test "parent correction resumes the same child with shared effects and its comment" do
    {:ok, resource} = Agent.start_link(fn -> %{value: 4, calls: 0} end)
    core = start_supervised!({EventCore, path: ":memory:"})
    start_supervised!({Projector, core: core})
    owner = self()

    resolver = fn ctx ->
      script =
        cond do
          ctx.depth == 0 and ctx.reason == "initial" ->
            [
              Fake.tool_call("delegate", %{
                "work_item" => %{"instruction" => "Reach 3 on the shared resource"},
                "comment" => "Observed value is 4"
              })
            ]

          ctx.depth == 1 and ctx.reason == "initial" ->
            [Fake.report("Observed value is still 4", true)]

          ctx.depth == 1 ->
            [
              fn messages ->
                send(owner, {:correction, messages})
                Fake.tool_call("counter_decrement", %{})
              end,
              Fake.report("Decrement returned 3")
            ]

          ctx.reason == "assessment" and Agent.get(resource, & &1.value) == 4 ->
            [
              Fake.report(
                "Decrement the existing shared resource once; do not create another Work Item.",
                false
              )
            ]

          true ->
            [Fake.report("Verified existing resource is 3")]
        end

      agent =
        Omunculus.Runtime.Agents.resolve(ctx, %{chat: Fake.new(script) |> Map.put(:model, "test")})

      %{
        agent
        | tools: if(ctx.depth == 0, do: ["delegate"], else: ["counter", "counter_decrement"]),
          max_retries: 1,
          tool_options: Map.put(agent.tool_options, :tools, %{"counter" => %{resource: resource}})
      }
    end

    start_supervised!({Runtime, core: core, max_depth: 1, agents: resolver})

    assert {:ok, %{result: "Verified existing resource is 3"}} =
             Runtime.request(core, "Reach 3", timeout: 5000)

    assert_receive {:correction, messages}

    assert Enum.any?(
             messages,
             &String.contains?(&1["content"] || "", "Decrement the existing shared resource once")
           )

    [delegation] = EventCore.stream(core, 0, type: "task.delegated")
    child = delegation.payload["child_work_item_id"]
    assert length(EventCore.stream(core, 0, type: "run.started", work_item_id: child)) == 2
    [recovery] = EventCore.stream(core, 0, type: "task.recovery_used")
    assert recovery.work_item_id == child
    assert Agent.get(resource, & &1) == %{value: 3, calls: 1, increment: -1}

    [effect] =
      Enum.filter(
        EventCore.stream(core, 0, type: "tool.call.completed"),
        &(&1.payload["tool"] == "counter_decrement")
      )

    assert effect.payload["previous"] == 4
    assert effect.payload["new"] == 3
    refute Enum.any?(EventCore.stream(core, 0), &(&1.type == "task.break"))
  end

  test "an impossible correction escalates without mutating the resource" do
    {:ok, resource} = Agent.start_link(fn -> %{value: 4, calls: 0} end)
    core = start_supervised!({EventCore, path: ":memory:"})
    start_supervised!({Projector, core: core})

    resolver = fn ctx ->
      script =
        if ctx.depth == 0 and ctx.reason == "initial" do
          [
            Fake.tool_call("delegate", %{
              "work_item" => %{"instruction" => "Reach 3 using increment only"},
              "comment" => "Shared resource is 4; no reset or decrement exists"
            })
          ]
        else
          [
            Fake.text(
              Jason.encode!(%{
                completed: false,
                break: true,
                comment:
                  "The resource is 4. Increment cannot reach 3; human intervention is required."
              })
            )
          ]
        end

      agent =
        Omunculus.Runtime.Agents.resolve(ctx, %{chat: Fake.new(script) |> Map.put(:model, "test")})

      %{
        agent
        | tools: if(ctx.depth == 0, do: ["delegate"], else: ["counter"]),
          max_retries: 1,
          tool_options: Map.put(agent.tool_options, :tools, %{"counter" => %{resource: resource}})
      }
    end

    start_supervised!({Runtime, core: core, max_depth: 1, agents: resolver})
    EventCore.subscribe(core)

    EventCore.append!(
      core,
      Omunculus.Event.Envelope.command("task.requested",
        work_item_id: "impossible",
        payload: %{instruction: "Reach 3"}
      )
    )

    assert_receive {:event_core,
                    %{type: "task.commented", payload: %{"assessment" => true} = request}},
                   5000

    assert request["body"] =~ "Increment cannot reach 3"
    assert Agent.get(resource, & &1) == %{value: 4, calls: 0}
    assert EventCore.stream(core, 0, type: "task.completed") == []
    assert EventCore.stream(core, 0, type: "task.recovery_used") == []

    assert Enum.all?(
             EventCore.stream(core, 0, type: "tool.call.requested"),
             &(&1.payload["tool"] == "delegate")
           )
  end
end
