defmodule Omunculus.Process.TreeTest do
  use ExUnit.Case, async: true

  alias Omunculus.Process.Tree

  # Whether the tree replays a trace: the languages of a block structured
  # model, by the rules of each operator.
  defp accepts?(tree, trace), do: [] in rest(tree, trace)

  defp rest(:tau, trace), do: [trace]
  defp rest({:leaf, a}, [a | tail]), do: [tail]
  defp rest({:leaf, _}, _trace), do: []

  defp rest({:seq, children}, trace),
    do:
      Enum.reduce(children, [trace], fn child, traces ->
        Enum.flat_map(traces, &rest(child, &1))
      end)

  defp rest({:xor, children}, trace), do: Enum.flat_map(children, &rest(&1, trace))

  defp rest({:loop, body, redo}, trace), do: loop(body, redo, trace, MapSet.new())

  defp loop(body, redo, trace, seen) do
    if MapSet.member?(seen, trace) do
      []
    else
      for after_body <- rest(body, trace),
          result <- [
            after_body
            | Enum.flat_map(
                rest(redo, after_body),
                &loop(body, redo, &1, MapSet.put(seen, trace))
              )
          ],
          do: result
    end
  end

  defp assert_fits(traces) do
    tree = Tree.mine(traces)

    for trace <- traces,
        do: assert(accepts?(tree, trace), "#{inspect(tree)} rejects #{inspect(trace)}")

    tree
  end

  test "a sequence" do
    assert {:seq, [{:leaf, "a"}, {:leaf, "b"}, {:leaf, "c"}]} =
             assert_fits([~w(a b c), ~w(a b c)])
  end

  test "an exclusive choice" do
    assert {:xor, [{:leaf, "a"}, {:leaf, "b"}]} = assert_fits([~w(a), ~w(b)])
  end

  test "a choice inside a sequence" do
    assert {:seq, [{:leaf, "a"}, {:xor, [{:leaf, "b"}, {:leaf, "c"}]}, {:leaf, "d"}]} =
             assert_fits([~w(a b d), ~w(a c d)])
  end

  test "a skippable activity is a choice with tau" do
    assert {:seq, [{:leaf, "a"}, {:xor, [:tau, {:leaf, "b"}]}, {:leaf, "c"}]} =
             assert_fits([~w(a b c), ~w(a c)])
  end

  test "a loop with a redo part" do
    assert {:loop, {:leaf, "a"}, {:xor, [{:leaf, "b"}, {:leaf, "c"}]}} =
             assert_fits([~w(a), ~w(a b a), ~w(a c a b a)])
  end

  test "a stage reopened is a loop back over a sequence" do
    tree = assert_fits([~w(to_do review), ~w(to_do review to_do review), ~w(to_do review)])
    assert {:loop, {:seq, [{:leaf, "to_do"}, {:leaf, "review"}]}, :tau} = tree
  end

  test "an activity that repeats is a loop with tau" do
    assert {:loop, {:leaf, "a"}, :tau} = assert_fits([~w(a), ~w(a a)])
  end

  test "activities that come and go in any order are a loop over their choice" do
    assert {:loop, {:xor, [{:leaf, "a"}, {:leaf, "b"}]}, :tau} =
             assert_fits([~w(a b), ~w(b a), ~w(a b a)])
  end

  test "what no cut tells apart falls to the flower, a loop of tau over any activity" do
    assert {:loop, :tau, {:xor, [{:leaf, "a"}, {:leaf, "b"}, {:leaf, "c"}, {:leaf, "d"}]}} =
             assert_fits([~w(d c a), ~w(a a), ~w(a d b a c)])
  end

  test "the empty log and the empty trace" do
    assert Tree.mine([]) == :tau
    assert {:xor, [:tau, {:leaf, "a"}]} = assert_fits([[], ~w(a)])
  end

  test "every trace of a mixed log is replayed" do
    traces = [
      ~w(plan build review),
      ~w(plan build review build review),
      ~w(plan review),
      ~w(plan build build review),
      ~w(build review),
      ~w(plan build review ship),
      ~w(plan plan build review)
    ]

    assert_fits(traces)
  end

  test "every trace of random logs is replayed" do
    :rand.seed(:exsss, {1, 2, 3})
    activities = ~w(a b c d e)

    for _round <- 1..200 do
      traces =
        for _trace <- 1..Enum.random(1..6),
            do: for(_step <- 1..Enum.random(1..7), do: Enum.random(activities))

      assert_fits(traces)
    end
  end

  test "mining is deterministic" do
    traces = [~w(a b c), ~w(a c b), ~w(a b)]
    assert Tree.mine(traces) == Tree.mine(Enum.reverse(traces))
  end
end
