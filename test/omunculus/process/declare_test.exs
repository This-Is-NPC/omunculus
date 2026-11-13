defmodule Omunculus.Process.DeclareTest do
  use ExUnit.Case, async: true

  alias Omunculus.Process.Declare

  defp work(id, state, activities),
    do: %{id: id, state: state, events: for(a <- activities, do: %{kind: :call, activity: a})}

  defp rule(rules, template, a, b),
    do: Enum.find(rules, &(&1.template == template and &1.a == a and &1.b == b))

  setup do
    works = [
      work("d1", "done", ~w(read write test ship)),
      work("d2", "done", ~w(write test ship)),
      work("d3", "done", ~w(read write test test ship)),
      work("d4", "done", ~w(read ship)),
      work("f1", "cancelled", ~w(write ship)),
      work("f2", "cancelled", ~w(read write test)),
      work("f3", "cancelled", ~w(test write))
    ]

    %{works: works}
  end

  test "a response rule is kept when the done works that activate it satisfy it", %{works: works} do
    rules = Declare.mine(works, 0.5, 1.0)

    assert %{support: 0.75, confidence: 1.0} = rule(rules, "response", "write", "test")
    assert rule(rules, "response", "write", "ship")
  end

  test "a precedence rule holds when the first of its activator follows the other", %{
    works: works
  } do
    rules = Declare.mine(works, 0.5, 1.0)
    assert %{support: 0.75, confidence: 1.0} = rule(rules, "precedence", "write", "test")
  end

  test "the cancelled works that activate a rule and break it are its violations", %{works: works} do
    rules = Declare.mine(works, 0.5, 1.0)

    assert ["f1", "f3"] = for(w <- rule(rules, "response", "write", "test").violations, do: w.id)
    assert ["f3"] = for(w <- rule(rules, "precedence", "write", "test").violations, do: w.id)
  end

  test "the thresholds cut what is below them", %{works: works} do
    # write activates it in three done works, and read comes first in two
    assert %{support: 0.5, confidence: confidence} =
             rule(Declare.mine(works, 0.5, 0.5), "precedence", "read", "write")

    assert_in_delta confidence, 2 / 3, 1.0e-9
    assert rule(Declare.mine(works, 0.5, 1.0), "precedence", "read", "write") == nil
    assert rule(Declare.mine(works, 0.8, 0.5), "precedence", "read", "write") == nil
  end

  test "the most violated rules come first", %{works: works} do
    rules = Declare.mine(works, 0.5, 0.5)
    most = rules |> Enum.map(&length(&1.violations)) |> Enum.max()
    assert most >= 2
    assert length(hd(rules).violations) == most
  end

  test "no done work gives no rule" do
    assert Declare.mine([work("f", "cancelled", ~w(a b))], 0, 0) == []
  end
end
