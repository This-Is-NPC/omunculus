defmodule Omunculus.Model.BatteryTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.Battery
  alias Omunculus.Tools.Out

  defp recorder(outputs \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> {[], outputs} end)

    call = fn name, args ->
      Agent.get_and_update(agent, fn {calls, outputs} ->
        {output, outputs} = pop_output(outputs, name)
        {output, {calls ++ [{name, args}], outputs}}
      end)
    end

    {agent, call}
  end

  defp pop_output(outputs, name) do
    case Map.get(outputs, name) do
      [next | rest] -> {{:ok, next}, Map.put(outputs, name, rest)}
      _no_queue -> {{:ok, ""}, outputs}
    end
  end

  defp calls(agent), do: agent |> Agent.get(& &1) |> elem(0)

  defp tools_section(names),
    do:
      "## Tools\n#{Out.tools_preamble()}\n" <>
        Enum.map_join(names, "\n", &"- #{&1}: a tool")

  defp tools(names), do: Enum.map(names, &%{name: &1, description: "a tool", parameters: %{}})

  defp complete(assembled, tools, call) do
    Battery.new(%{}).(assembled, tools, call, fn _text -> :ok end, nil)
  end

  @count_work %{"title" => "Count to 5", "goal" => "count with counter to 5"}

  test "rule 1: without a work, opens one with work and its report, without counting" do
    names = ~w(work counter)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder()

    assert {:ok, "opened"} = complete(assembled, tools(names), call)

    assert calls(agent) == [{"work", %{"report" => "opened", "works" => [@count_work]}}]
  end

  test "rule 1 without the work card: counts in the run" do
    names = ~w(counter)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder(%{"counter" => ["5"]})

    assert {:ok, "counted to 5"} = complete(assembled, tools(names), call)
    assert calls(agent) == [{"counter", %{}}]
  end

  test "delegates one floor down with work when it cannot count" do
    names = ~w(work done)

    assembled =
      Enum.join(
        [
          "You are the manager.",
          "## Work\nCount to 5",
          "## Last comment\nopened",
          tools_section(names)
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "delegated"} = complete(assembled, tools(names), call)
    assert calls(agent) == [{"work", %{"report" => "delegated", "works" => [@count_work]}}]
  end

  test "does not delegate again once its last comment says it delegated" do
    names = ~w(work done)

    assembled =
      Enum.join(
        [
          "You are the manager.",
          "## Work\nCount to 5",
          "## Last comment\ndelegated",
          tools_section(names)
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "nothing to do"} = complete(assembled, tools(names), call)
    assert calls(agent) == []
  end

  test "rule 2 without done: counts to 5 with counter, stopping as soon as it reaches 5, then comments and notifies" do
    names = ~w(counter comment notify)

    assembled =
      Enum.join(
        ["You are the worker.", "## Work\nCount to 5", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder(%{"counter" => ["1", "2", "3", "4", "5"]})

    assert {:ok, "counted to 5"} = complete(assembled, tools(names), call)

    assert calls(agent) ==
             List.duplicate({"counter", %{}}, 5) ++
               [{"comment", %{"body" => "counted to 5"}}, {"notify", %{"body" => "reached 5"}}]
  end

  test "rule 2 with done: notifies, then concludes with done carrying the count" do
    names = ~w(counter comment notify done)

    assembled =
      Enum.join(["You are the worker.", "## Work\nCount to 5", tools_section(names)], "\n\n")

    {agent, call} = recorder(%{"counter" => ["5"]})

    assert {:ok, "counted to 5"} = complete(assembled, tools(names), call)

    assert calls(agent) == [
             {"counter", %{}},
             {"notify", %{"body" => "reached 5"}},
             {"done", %{"report" => "counted to 5"}}
           ]
  end

  test "rule 2 stops as soon as the counter reaches 5 without exhausting the 5 calls" do
    names = ~w(counter)
    assembled = Enum.join(["You are the worker.", tools_section(names)], "\n\n")

    {agent, call} = recorder(%{"counter" => ["4", "5"]})

    assert {:ok, "counted to 5"} = complete(assembled, tools(names), call)

    call_names = calls(agent) |> Enum.map(&elem(&1, 0))
    assert call_names == ["counter", "counter"]
  end

  test "rule 3: a last comment announcing the count and a done card conclude the review" do
    names = ~w(done)

    assembled =
      Enum.join(
        ["You are the concierge.", "## Last comment\ncounted to 5", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "reviewed"} = complete(assembled, tools(names), call)
    assert calls(agent) == [{"done", %{"report" => "reviewed"}}]
  end

  test "rule 4: an agent addressed as observer comments on the work it is watching" do
    names = ~w(comment)

    assembled =
      Enum.join(
        ["You are the observer. Record the notification.", "## Work\nHelp", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "observed"} = complete(assembled, tools(names), call)
    assert calls(agent) == [{"comment", %{"body" => "observed"}}]
  end

  test "rule 5: nothing matches, so it calls no tool and reports there is nothing to do" do
    names = ~w(comment)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder()

    assert {:ok, "nothing to do"} = complete(assembled, tools(names), call)
    assert calls(agent) == []
  end
end
