defmodule Omunculus.Process.Tree do
  @moduledoc """
  A process tree mined from traces, a list of activities each, by the
  inductive miner: `{:leaf, activity}`, `:tau` (nothing), `{:seq, children}`,
  `{:xor, children}` and `{:loop, body, redo}`, which does the body and then,
  any number of times, the redo and the body again.

  A log is cut, in this order, by an exclusive choice (the directly-follows
  graph falls apart), a sequence (its strongly connected parts come in a
  fixed order), a loop (what is left once the start and end activities are
  taken out gives the redo parts) and, failing those, a loop of tau over the
  traces split at each start activity, or the flower, a loop that does any
  activity in any order. Each cut splits the traces into the logs of its
  children, so the tree replays every trace it was mined from, and a tree is
  block structured, so what it becomes is sound. It does not find parallel
  branches; the stages of a work are sequential, and the flower covers the
  rest. No noise is filtered.
  """

  @type t :: :tau | {:leaf, term} | {:seq, [t]} | {:xor, [t]} | {:loop, t, t}

  @spec mine([[term]]) :: t
  def mine(traces) do
    case Enum.split_with(traces, &(&1 == [])) do
      {_empty, []} -> :tau
      {[], traces} -> cut(traces)
      {_empty, traces} -> xor([:tau, cut(traces)])
    end
  end

  defp cut(traces) do
    alphabet = traces |> Enum.concat() |> Enum.uniq() |> Enum.sort()

    case alphabet do
      [activity] ->
        if Enum.all?(traces, &(&1 == [activity])),
          do: {:leaf, activity},
          else: {:loop, {:leaf, activity}, :tau}

      _many ->
        graph = graph(traces, alphabet)

        with :none <- exclusive(traces, graph),
             :none <- sequence(traces, graph),
             :none <- loop(traces, graph),
             :none <- repeated(traces, graph),
             do: {:loop, :tau, xor(Enum.map(alphabet, &{:leaf, &1}))}
    end
  end

  defp graph(traces, alphabet) do
    edges = for trace <- traces, {a, b} <- Enum.zip(trace, tl(trace)), uniq: true, do: {a, b}

    %{
      alphabet: alphabet,
      edges: MapSet.new(edges),
      starts: traces |> Enum.map(&hd/1) |> MapSet.new(),
      ends: traces |> Enum.map(&List.last/1) |> MapSet.new()
    }
  end

  defp exclusive(traces, graph) do
    case components(graph.alphabet, graph.edges) do
      [_one] ->
        :none

      parts ->
        xor(for part <- parts, do: mine(Enum.filter(traces, &(hd(&1) in part))))
    end
  end

  # Weakly connected parts of the graph over `nodes`: each node joins the
  # parts it shares an edge with.
  defp components(nodes, edges) do
    Enum.reduce(nodes, [], fn node, parts ->
      {touching, apart} =
        Enum.split_with(parts, fn part ->
          Enum.any?(
            part,
            &(MapSet.member?(edges, {&1, node}) or MapSet.member?(edges, {node, &1}))
          )
        end)

      [Enum.sort([node | Enum.concat(touching)]) | apart]
    end)
    |> Enum.sort()
  end

  defp sequence(traces, graph) do
    reach = closure(graph.edges)

    classes =
      Enum.reduce(graph.alphabet, [], fn node, classes ->
        {kin, apart} =
          Enum.split_with(classes, fn class ->
            Enum.any?(class, &related?(reach, node, &1))
          end)

        [Enum.sort([node | Enum.concat(kin)]) | apart]
      end)

    with [_, _ | _] <- classes,
         ordered =
           Enum.sort_by(classes, fn class -> Enum.count(classes, &before?(reach, &1, class)) end),
         true <- ordered?(reach, ordered) do
      {:seq,
       for class <- ordered do
         mine(Enum.map(traces, fn trace -> Enum.filter(trace, &(&1 in class)) end))
       end}
      |> flatten()
    else
      _ -> :none
    end
  end

  # Two activities stay together when each reaches the other or neither does.
  defp related?(reach, a, b), do: MapSet.member?(reach, {a, b}) == MapSet.member?(reach, {b, a})

  defp before?(reach, class, other),
    do:
      class != other and
        Enum.any?(class, fn a -> Enum.any?(other, &MapSet.member?(reach, {a, &1})) end)

  defp ordered?(reach, ordered) do
    for {class, index} <- Enum.with_index(ordered),
        later <- Enum.drop(ordered, index + 1),
        reduce: true do
      acc -> acc and not before?(reach, later, class)
    end
  end

  # Every pair that a path of one or more edges joins.
  defp closure(edges) do
    next = for {a, b} <- edges, {^b, c} <- edges, into: edges, do: {a, c}
    if MapSet.size(next) == MapSet.size(edges), do: edges, else: closure(next)
  end

  defp loop(traces, graph) do
    kept =
      for {a, b} = edge <- graph.edges,
          a not in graph.ends and b not in graph.starts,
          do: edge

    parts = components(graph.alphabet, MapSet.new(kept))
    anchors = MapSet.union(graph.starts, graph.ends)
    {body, redo} = Enum.split_with(parts, fn part -> Enum.any?(part, &(&1 in anchors)) end)

    if redo == [] do
      :none
    else
      body = Enum.concat(body)
      {:loop, mine(runs(traces, body, true)), mine(runs(traces, body, false))}
    end
  end

  # The maximal runs of `body` activities (or of the others) in each trace.
  defp runs(traces, body, in_body) do
    Enum.flat_map(traces, fn trace ->
      trace
      |> Enum.chunk_by(&(&1 in body))
      |> Enum.filter(fn [first | _] -> first in body == in_body end)
    end)
  end

  # Traces that start an activity again after their first one, cut there.
  defp repeated(traces, graph) do
    parts = Enum.map(traces, &split(&1, graph.starts))

    if Enum.all?(parts, &match?([_], &1)),
      do: :none,
      else: parts |> Enum.concat() |> mine() |> repeat()
  end

  # The flower already repeats.
  defp repeat({:loop, :tau, _any} = flower), do: flower
  defp repeat(body), do: {:loop, body, :tau}

  defp split([first | rest], starts) do
    {parts, last} =
      Enum.reduce(rest, {[], [first]}, fn activity, {parts, current} ->
        if activity in starts,
          do: {[Enum.reverse(current) | parts], [activity]},
          else: {parts, [activity | current]}
      end)

    Enum.reverse([Enum.reverse(last) | parts])
  end

  defp xor(children) do
    {:xor,
     Enum.flat_map(children, fn
       {:xor, inner} -> inner
       other -> [other]
     end)}
  end

  defp flatten({:seq, children}) do
    {:seq,
     Enum.flat_map(children, fn
       {:seq, inner} -> inner
       other -> [other]
     end)}
  end
end
