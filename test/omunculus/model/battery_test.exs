defmodule Omunculus.Model.BatteryTest do
  use ExUnit.Case, async: true

  alias Omunculus.Model.Battery

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

  defp tools_section(cards),
    do: "## Tools\nAs tools estão em `tools.*`.\n" <> Enum.join(cards, "\n")

  defp card(name), do: "- #{name}: uma tool"

  test "rule 1 with delegate: opens the work then delegates, ending before counting" do
    assembled =
      Enum.join(
        [
          "Você é o concierge.",
          tools_section([card("work"), card("delegate"), card("counter")])
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, _result} = Battery.complete(assembled, call)

    assert calls(agent) == [
             {"work", %{"title" => "Contar até 5"}},
             {"delegate", %{"title" => "Conte até 5", "body" => "conte com counter até 5"}}
           ]
  end

  test "rule 1 without delegate: opens the work and falls through to counting" do
    assembled =
      Enum.join(
        [
          "Você é o concierge.",
          tools_section([card("work"), card("counter")])
        ],
        "\n\n"
      )

    {agent, call} = recorder(%{"counter" => ["1", "2", "3", "4", "5"]})

    assert {:ok, "contei até 5"} = Battery.complete(assembled, call)

    [first | rest] = calls(agent)
    assert first == {"work", %{"title" => "Contar até 5"}}
    assert Enum.count(rest, fn {name, _args} -> name == "counter" end) == 5
  end

  test "rule 2: counts to 5 with counter, stopping as soon as it reaches 5, then comments, notifies and continues" do
    assembled =
      Enum.join(
        [
          "Você é o worker.",
          "## Work\nContar até 5",
          tools_section([
            card("counter"),
            card("comment"),
            card("notify"),
            card("continue")
          ])
        ],
        "\n\n"
      )

    {agent, call} = recorder(%{"counter" => ["1", "2", "3", "4", "5"]})

    assert {:ok, "contei até 5"} = Battery.complete(assembled, call)

    names = calls(agent) |> Enum.map(&elem(&1, 0))
    assert Enum.count(names, &(&1 == "counter")) == 5

    assert names == [
             "counter",
             "counter",
             "counter",
             "counter",
             "counter",
             "comment",
             "notify",
             "continue"
           ]

    assert {"comment", %{"body" => "contei até 5"}} in calls(agent)
    assert {"notify", %{"body" => "cheguei a 5"}} in calls(agent)
    assert {"continue", %{}} in calls(agent)
  end

  test "rule 2 stops as soon as the counter reaches 5 without exhausting the 5 calls" do
    assembled =
      Enum.join(
        [
          "Você é o worker.",
          tools_section([card("counter")])
        ],
        "\n\n"
      )

    {agent, call} = recorder(%{"counter" => ["4", "5"]})

    assert {:ok, "contei até 5"} = Battery.complete(assembled, call)

    names = calls(agent) |> Enum.map(&elem(&1, 0))
    assert names == ["counter", "counter"]
  end

  test "rule 3: a last comment announcing the count and a continue card advance the review" do
    assembled =
      Enum.join(
        [
          "Você é o concierge.",
          "## Last comment\ncontei até 5",
          tools_section([card("continue")])
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "revisado"} = Battery.complete(assembled, call)
    assert calls(agent) == [{"continue", %{}}]
  end

  test "rule 4: an agent addressed as observer comments on the work it is watching" do
    assembled =
      Enum.join(
        [
          "Você é o observer. Registre o aviso.",
          "## Work\nAjuda",
          tools_section([card("comment")])
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "observado"} = Battery.complete(assembled, call)
    assert calls(agent) == [{"comment", %{"body" => "observado"}}]
  end

  test "rule 5: nothing matches, so it calls no tool and reports there is nothing to do" do
    assembled =
      Enum.join(
        [
          "Você é o concierge.",
          tools_section([card("comment")])
        ],
        "\n\n"
      )

    {agent, call} = recorder()

    assert {:ok, "nada a fazer"} = Battery.complete(assembled, call)
    assert calls(agent) == []
  end
end
