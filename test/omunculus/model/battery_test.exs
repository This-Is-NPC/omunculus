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

  test "rule 1 with delegate: opens the work then delegates, ending before counting" do
    names = ~w(work delegate counter)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder()

    assert {:ok, _result} = Battery.complete(assembled, tools(names), call)

    assert calls(agent) == [
             {"work", %{"title" => "Count to 5"}},
             {"delegate", %{"title" => "Count to 5", "body" => "count with counter to 5"}}
           ]
  end

  test "rule 1 without delegate: opens the work and falls through to counting" do
    names = ~w(work counter)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder(%{"counter" => ["1", "2", "3", "4", "5"]})

    assert {:ok, "counted to 5"} = Battery.complete(assembled, tools(names), call)

    [first | rest] = calls(agent)
    assert first == {"work", %{"title" => "Count to 5"}}
    assert Enum.count(rest, fn {name, _args} -> name == "counter" end) == 5
  end

  test "rule 2: counts to 5 with counter, stopping as soon as it reaches 5, then comments, notifies and continues" do
    names = ~w(counter comment notify continue)

    assembled =
      Enum.join(
        ["You are the worker.", "## Work\nCount to 5", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder(%{"counter" => ["1", "2", "3", "4", "5"]})

    assert {:ok, "counted to 5"} = Battery.complete(assembled, tools(names), call)

    call_names = calls(agent) |> Enum.map(&elem(&1, 0))
    assert Enum.count(call_names, &(&1 == "counter")) == 5

    assert call_names == [
             "counter",
             "counter",
             "counter",
             "counter",
             "counter",
             "comment",
             "notify",
             "continue"
           ]

    assert {"comment", %{"body" => "counted to 5"}} in calls(agent)
    assert {"notify", %{"body" => "reached 5"}} in calls(agent)
    assert {"continue", %{}} in calls(agent)
  end

  test "rule 2 stops as soon as the counter reaches 5 without exhausting the 5 calls" do
    names = ~w(counter)
    assembled = Enum.join(["You are the worker.", tools_section(names)], "\n\n")

    {agent, call} = recorder(%{"counter" => ["4", "5"]})

    assert {:ok, "counted to 5"} = Battery.complete(assembled, tools(names), call)

    call_names = calls(agent) |> Enum.map(&elem(&1, 0))
    assert call_names == ["counter", "counter"]
  end

  test "rule 3: a last comment announcing the count and a continue card advance the review" do
    names = ~w(continue)

    assembled =
      Enum.join(
        ["You are the concierge.", "## Last comment\ncounted to 5", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "reviewed"} = Battery.complete(assembled, tools(names), call)
    assert calls(agent) == [{"continue", %{}}]
  end

  test "rule 4: an agent addressed as observer comments on the work it is watching" do
    names = ~w(comment)

    assembled =
      Enum.join(
        ["You are the observer. Record the notification.", "## Work\nHelp", tools_section(names)],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "observed"} = Battery.complete(assembled, tools(names), call)
    assert calls(agent) == [{"comment", %{"body" => "observed"}}]
  end

  test "rule 5: nothing matches, so it calls no tool and reports there is nothing to do" do
    names = ~w(comment)
    assembled = Enum.join(["You are the concierge.", tools_section(names)], "\n\n")

    {agent, call} = recorder()

    assert {:ok, "nothing to do"} = Battery.complete(assembled, tools(names), call)
    assert calls(agent) == []
  end
end
