defmodule Omunculus.Chat.FakeTest do
  use ExUnit.Case, async: true

  alias Omunculus.Chat.Fake
  alias Omunculus.Runtime.Agents

  test "new/1 still builds a scripted chat from a turn list" do
    chat = Fake.new([Fake.text("hello")])

    assert {:ok, %{content: "hello"}} = Fake.complete(chat, [], [])
    assert {:error, :no_scripted_turns} = Fake.complete(chat, [], [])
  end

  test "for_node branches turns by agent_id" do
    script = fn agent_id, depth, _workspace, _team ->
      [Fake.text("#{agent_id}@#{depth}")]
    end

    concierge = Fake.for_node(script, "concierge", 0, nil, nil)
    worker = Fake.for_node(script, "worker", 1, nil, nil)

    assert {:ok, %{content: "concierge@0"}} = Fake.complete(concierge, [], [])
    assert {:ok, %{content: "worker@1"}} = Fake.complete(worker, [], [])
  end

  test "for_node branches turns by team" do
    script = fn _agent_id, _depth, _workspace, team ->
      [Fake.text(if(team, do: "team:#{team}", else: "solo"))]
    end

    solo = Fake.for_node(script, "worker", 1, nil, nil)
    teamed = Fake.for_node(script, "worker", 1, nil, "alpha")

    assert {:ok, %{content: "solo"}} = Fake.complete(solo, [], [])
    assert {:ok, %{content: "team:alpha"}} = Fake.complete(teamed, [], [])
  end

  test "Agents.resolver uses :script for fake concierge and worker chats" do
    seen = :ets.new(:seen, [:set, :private])

    script = fn agent_id, depth, workspace, team ->
      :ets.insert(seen, {agent_id, depth, workspace, team})

      case agent_id do
        "concierge" ->
          [
            Fake.tool_call(
              "delegate",
              %{
                "comment" => "Preserve this task context and review the result",
                "instruction" => "conte até 1"
              },
              "call_delegate"
            ),
            Fake.text("concierge-scripted")
          ]

        "worker" ->
          [
            Fake.tool_call("counter", %{}, "call_counter_1"),
            Fake.text("worker-scripted")
          ]
      end
    end

    resolver = Agents.resolver(script: script, target: 1)

    config = %{
      Omunculus.Config.empty()
      | teams: %{"team-a" => %{lead: "concierge", members: ["worker"]}}
    }

    concierge =
      resolver.(%{
        depth: 0,
        max_depth: 1,
        instruction: "conte até 1",
        checkpoint: %{},
        workspace: "ws-1",
        config: config,
        team: "team-a"
      })

    assert [{"concierge", 0, "ws-1", "team-a"}] = :ets.tab2list(seen)

    assert {:ok, %{tool_calls: [_]}} = Fake.complete(concierge.chat, [], [])
    assert {:ok, %{content: "concierge-scripted"}} = Fake.complete(concierge.chat, [], [])

    worker =
      resolver.(%{
        agent: "worker",
        depth: 1,
        max_depth: 1,
        instruction: "conte até 1",
        checkpoint: %{},
        workspace: "ws-1",
        config: config,
        team: "team-a"
      })

    assert Enum.sort(:ets.tab2list(seen)) ==
             Enum.sort([
               {"concierge", 0, "ws-1", "team-a"},
               {"worker", 1, "ws-1", "team-a"}
             ])

    assert {:ok, %{tool_calls: [_]}} = Fake.complete(worker.chat, [], [])
    assert {:ok, %{content: "worker-scripted"}} = Fake.complete(worker.chat, [], [])
  end

  test "default spike scripts still delegate then text for concierge and counter then text for worker" do
    resolver = Agents.resolver(target: 2)

    concierge =
      resolver.(%{
        depth: 0,
        max_depth: 1,
        instruction: "conte até 2",
        checkpoint: %{}
      })

    assert {:ok, %{tool_calls: [call]}} = Fake.complete(concierge.chat, [], [])
    assert call["function"]["name"] == "delegate"

    assert {:ok, %{content: content}} =
             Fake.complete(concierge.chat, [%{"role" => "tool", "content" => "Result: 2"}], [])

    assert Jason.decode!(content)["comment"] == "2"

    worker =
      resolver.(%{
        depth: 1,
        max_depth: 1,
        instruction: "conte até 2",
        checkpoint: %{}
      })

    assert {:ok, %{tool_calls: [call1]}} = Fake.complete(worker.chat, [], [])
    assert call1["id"] == "call_counter_1"

    assert {:ok, %{tool_calls: [call2]}} =
             Fake.complete(
               worker.chat,
               [%{"role" => "tool", "content" => "Counter value: 1"}],
               []
             )

    assert call2["id"] == "call_counter_2"

    assert {:ok, %{content: content}} =
             Fake.complete(
               worker.chat,
               [%{"role" => "tool", "content" => "Counter value: 2"}],
               []
             )

    assert Jason.decode!(content)["comment"] == "2"
  end

  test "default worker script resumes from checkpoint with remaining counter calls" do
    resolver = Agents.resolver(target: 3)

    worker =
      resolver.(%{
        depth: 1,
        max_depth: 1,
        instruction: "conte até 3",
        checkpoint: %{"tool_state" => %{"counter" => %{value: 1}}}
      })

    assert {:ok, %{tool_calls: [call]}} = Fake.complete(worker.chat, [], [])
    assert call["id"] == "call_counter_2"

    assert {:ok, %{tool_calls: [call]}} =
             Fake.complete(
               worker.chat,
               [%{"role" => "tool", "content" => "Counter value: 2"}],
               []
             )

    assert call["id"] == "call_counter_3"

    assert {:ok, %{content: content}} =
             Fake.complete(
               worker.chat,
               [%{"role" => "tool", "content" => "Counter value: 3"}],
               []
             )

    assert Jason.decode!(content)["comment"] == "3"
  end
end
