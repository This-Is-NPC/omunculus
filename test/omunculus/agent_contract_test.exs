defmodule Omunculus.AgentContractTest do
  use ExUnit.Case, async: false
  alias Omunculus.{Config, Chat.Fake, EventCore, Runtime}
  alias Omunculus.EventCore.Projector
  alias Omunculus.Runtime.Agents

  test "configured stage tools narrow the policy and reviewer receives reference criteria" do
    dir = Path.join(System.tmp_dir!(), "agent-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "omunculus.toml"), """
    [defaults]
    workflow = "delivery"
    [profiles.count]
    mode = "deny"
    granted = ["counter", "read"]
    instructions = "Increment once"
    [agents.worker]
    tools = ["counter", "write"]
    [agents.reviewer]
    tools = ["read"]
    [workflows.delivery]
    steps = [
      {name = "implement", instructions = "Produce one effect"},
      {name = "review", agent = "reviewer", instructions = "Read evidence without modifying it"}
    ]
    """)

    owner = self()
    core = start_supervised!({EventCore, path: ":memory:"})
    projector = start_supervised!({Projector, core: core})

    resolver = fn ctx ->
      script =
        if ctx.reason == "initial" do
          [Fake.tool_call("counter", %{}), Fake.report("One increment")]
        else
          [
            fn messages ->
              send(owner, {:review_messages, messages})
              Fake.tool_call("counter", %{})
            end,
            Fake.tool_call("read", %{"path" => "evidence.txt"}),
            Fake.report("Evidence checked")
          ]
        end

      Agents.resolve(ctx, %{chat: Fake.new(script) |> Map.put(:model, "contract-test")})
    end

    runtime =
      start_supervised!(
        {Runtime,
         core: core,
         max_depth: 0,
         agents: resolver,
         config: [cwd: dir, profile: "count"],
         run_opts: [fs: Omunculus.FS.Memory.new(%{"evidence.txt" => "One effect"})]}
      )

    assert {:ok, %{result: "Evidence checked"}} =
             Runtime.request(core, "Increment once", timeout: 3000)

    GenServer.stop(runtime)
    Projector.sync(projector)
    [worker, reviewer] = EventCore.stream(core, 0, type: "run.started")
    assert worker.payload["tools"]["granted"] == ["counter"]
    assert reviewer.payload["tools"]["granted"] == ["read"]
    effects = EventCore.stream(core, 0, type: "tool.call.completed")

    assert Enum.count(
             effects,
             &(&1.payload["tool"] == "counter" and &1.payload["outcome"] == "completed")
           ) == 1

    assert Enum.any?(
             effects,
             &(&1.payload["tool"] == "read" and &1.payload["outcome"] == "completed")
           )

    assert_receive {:review_messages, messages}
    assert hd(messages)["content"] =~ "Reference criteria"
    assert Enum.any?(messages, &((&1["content"] || "") =~ "Confirmed tool state:"))
    before = Projector.snapshot(core)
    Projector.rebuild(projector)
    assert Projector.snapshot(core) == before
  end

  test "agent tools reject unknown names and invalid shapes" do
    for tools <- [["missing"], [5], "counter"] do
      config = %{Config.empty() | agents: %{"worker" => %{tools: tools}}}
      assert {:error, {:invalid_agent_tools, "worker", _}} = Config.check(config)
    end

    config = %{Config.empty() | agents: %{"worker" => %{tools: []}}}
    assert {:ok, _} = Config.check(config)

    agent =
      Agents.resolve(%{config: config, depth: 0, max_depth: 0}, %{
        chat: Fake.new([]) |> Map.put(:model, "test")
      })

    assert agent.tools == []
  end

  test "assessment preserves the parent's own tool state through approval" do
    core = start_supervised!({EventCore, path: ":memory:"})
    start_supervised!({Projector, core: core})

    resolver = fn ctx ->
      script =
        cond do
          ctx.depth == 1 ->
            [Fake.report("Child delivered")]

          ctx.reason == "initial" ->
            [
              Fake.tool_call("counter", %{}),
              Fake.tool_call("delegate", %{
                "instruction" => "Deliver",
                "comment" => "Parent recorded one effect"
              })
            ]

          ctx.reason == "assessment" ->
            [Fake.tool_call("counter", %{}), Fake.report("Child approved")]

          ctx.reason == "continuation" ->
            [Fake.tool_call("counter", %{}), Fake.report("Parent complete")]
        end

      Agents.resolve(ctx, %{chat: Fake.new(script) |> Map.put(:model, "test")})
      |> Map.put(:tools, if(ctx.depth == 0, do: ["counter", "delegate"], else: []))
    end

    start_supervised!(
      {Runtime,
       core: core, max_depth: 1, agents: resolver, run_opts: [fs: Omunculus.FS.Memory.new()]}
    )

    assert {:ok, %{result: "Parent complete"}} = Runtime.request(core, "Deliver", timeout: 3000)

    assert [1, 2, 3] ==
             Enum.map(
               EventCore.stream(core, 0, type: "tool.call.completed")
               |> Enum.filter(&(&1.payload["tool"] == "counter")),
               & &1.payload["new"]
             )
  end
end
