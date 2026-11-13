defmodule Omunculus.Process.BpmnTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Process.Bpmn

  @flow_tags ~w(bpmn:startEvent bpmn:endEvent bpmn:task bpmn:exclusiveGateway)

  # xmerl ships with Erlang but is not among the application's own.
  setup_all do
    [ebin] = Path.wildcard(Path.join([:code.root_dir(), "lib", "xmerl-*", "ebin"]))
    true = Code.prepend_path(ebin)
    :ok
  end

  # The XML as a tree of {tag, attributes, children}; text is dropped but for
  # what documentation holds.
  defp parse(xml) do
    {root, _rest} = xml |> String.to_charlist() |> :xmerl_scan.string(quiet: true)
    tree(root)
  end

  # xmerl's records: {:xmlElement, name, _, _, _, _, _, attributes, content, ...},
  # {:xmlAttribute, name, _, _, _, _, _, _, value, _}, {:xmlText, _, _, _, value, _}.
  defp tree({:xmlElement, name, _, _, _, _, _, attributes, content, _, _, _}) do
    {Atom.to_string(name),
     Map.new(attributes, fn {:xmlAttribute, n, _, _, _, _, _, _, v, _} ->
       {Atom.to_string(n), to_string(v)}
     end), for(child <- content, is_tuple(child), do: leaf(child))}
  end

  defp leaf({:xmlElement, _, _, _, _, _, _, _, _, _, _, _} = child), do: tree(child)
  defp leaf({:xmlText, _, _, _, value, _}), do: to_string(value)

  defp find(tree, tag), do: find_all(tree, &(elem(&1, 0) == tag))

  defp find_all({_tag, _attrs, children} = node, pred) do
    own = if pred.(node), do: [node], else: []

    own ++
      Enum.flat_map(children, fn child ->
        if is_tuple(child), do: find_all(child, pred), else: []
      end)
  end

  defp attrs({_tag, attrs, _children}), do: attrs

  defp model(xml) do
    tree = parse(xml)
    nodes = tree |> find_all(&(elem(&1, 0) in @flow_tags))
    flows = find(tree, "bpmn:sequenceFlow")
    shapes = find(tree, "bpmndi:BPMNShape")
    edges = find(tree, "bpmndi:BPMNEdge")
    %{tree: tree, nodes: nodes, flows: flows, shapes: shapes, edges: edges}
  end

  defp ids(nodes), do: Enum.map(nodes, &attrs(&1)["id"])

  defp bounds(shape) do
    [bounds] = find(shape, "dc:Bounds")
    for key <- ~w(x y width height), do: String.to_integer(attrs(bounds)[key])
  end

  defp points(edge),
    do:
      for(
        point <- find(edge, "di:waypoint"),
        do: {String.to_integer(attrs(point)["x"]), String.to_integer(attrs(point)["y"])}
      )

  # The BPMN is a well formed, connected, laid out graph from one start to one end.
  defp assert_sound(xml) do
    %{nodes: nodes, flows: flows, shapes: shapes, edges: edges} = model(xml)
    node_ids = ids(nodes)

    assert length(Enum.uniq(node_ids ++ ids(flows))) == length(node_ids) + length(flows)
    assert Enum.count(nodes, &(elem(&1, 0) == "bpmn:startEvent")) == 1
    assert Enum.count(nodes, &(elem(&1, 0) == "bpmn:endEvent")) == 1

    graph = for flow <- flows, do: {attrs(flow)["sourceRef"], attrs(flow)["targetRef"]}
    assert Enum.all?(graph, fn {from, to} -> from in node_ids and to in node_ids end)

    [start] = for n <- nodes, elem(n, 0) == "bpmn:startEvent", do: attrs(n)["id"]
    [finish] = for n <- nodes, elem(n, 0) == "bpmn:endEvent", do: attrs(n)["id"]
    forward = reach(start, graph)
    backward = reach(finish, Enum.map(graph, fn {from, to} -> {to, from} end))
    assert Enum.sort(forward) == Enum.sort(node_ids)
    assert Enum.sort(backward) == Enum.sort(node_ids)

    # Every element and flow is drawn, flows by orthogonal segments.
    assert Enum.sort(Enum.map(shapes, &attrs(&1)["bpmnElement"])) == Enum.sort(node_ids)
    assert Enum.sort(Enum.map(edges, &attrs(&1)["bpmnElement"])) == Enum.sort(ids(flows))

    for edge <- edges do
      points = points(edge)
      assert length(points) >= 2

      for {{x1, y1}, {x2, y2}} <- Enum.zip(points, tl(points)),
          do:
            assert(x1 == x2 or y1 == y2, "a diagonal in #{attrs(edge)["id"]}: #{inspect(points)}")
    end

    boxes = Enum.map(shapes, &bounds/1)

    for {a, i} <- Enum.with_index(boxes), {b, j} <- Enum.with_index(boxes), i < j do
      refute overlap?(a, b), "shapes overlap: #{inspect(a)} #{inspect(b)}"
    end

    # A gateway that joins what another split: as many of each.
    gateways =
      for n <- nodes, elem(n, 0) == "bpmn:exclusiveGateway", do: attrs(n)["gatewayDirection"]

    assert Enum.count(gateways, &(&1 == "Diverging")) ==
             Enum.count(gateways, &(&1 == "Converging"))

    xml
  end

  defp reach(from, graph), do: reach([from], graph, MapSet.new([from])) |> MapSet.to_list()

  defp reach([], _graph, seen), do: seen

  defp reach([node | rest], graph, seen) do
    next = for {^node, to} <- graph, not MapSet.member?(seen, to), uniq: true, do: to
    reach(rest ++ next, graph, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  defp overlap?([x1, y1, w1, h1], [x2, y2, w2, h2]),
    do: x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1

  defp task_names(xml), do: for(task <- find(parse(xml), "bpmn:task"), do: attrs(task)["name"])

  defp config do
    Fixtures.config("""
    [agents.concierge]
    depth = 0
    text = "hi"
    [agents.worker]
    depth = 1
    text = "work"
    tools = ["read", "write"]
    [agents.reviewer]
    depth = 1
    text = "review"
    workflow_only = true
    [workflows.delivery]
    steps = [
      { name = "to_do", agent = "worker" },
      { name = "review", agent = "reviewer", deny = ["write"], overrides = { done = { then = [] } } },
    ]
    """)
  end

  test "the to-be is the workflow's stages in order, each with its agent" do
    config = config()
    xml = Bpmn.to_be("delivery", config.workflows["delivery"], config.agents) |> assert_sound()

    assert task_names(xml) == ["to_do (worker)", "review (reviewer)"]
    assert xml =~ ~s(<bpmn:process id="Process_1" name="delivery")
  end

  test "the to-be documents what gates a stage" do
    config = config()
    xml = Bpmn.to_be("delivery", config.workflows["delivery"], config.agents)

    assert xml =~ "agent: reviewer (depth 1, model "
    assert xml =~ "the stage denies: write"
    assert xml =~ "tools gated by overrides: done"
    assert xml =~ "the agent grants: read, write"
  end

  test "the as-is of a sequence is the sequence" do
    xml = Bpmn.as_is("delivery", [~w(to_do review), ~w(to_do review)]) |> assert_sound()
    assert task_names(xml) == ["to_do (2)", "review (2)"]
    refute xml =~ "exclusiveGateway"
  end

  test "the as-is of a choice has a split and a join" do
    xml = Bpmn.as_is("flow", [~w(a b d), ~w(a c d)]) |> assert_sound()
    assert task_names(xml) == ["a (2)", "b (1)", "c (1)", "d (2)"]
    assert xml =~ ~s(gatewayDirection="Diverging")
    assert xml =~ ~s(gatewayDirection="Converging")
  end

  test "the as-is of a stage reopened has its way back" do
    xml =
      Bpmn.as_is("delivery", [~w(to_do review), ~w(to_do review to_do review)]) |> assert_sound()

    assert task_names(xml) == ["to_do (3)", "review (3)"]
  end

  test "the as-is of a loop with a redo part and of a skippable stage is sound" do
    assert_sound(Bpmn.as_is("loop", [~w(a), ~w(a b a), ~w(a c a b a)]))
    assert_sound(Bpmn.as_is("optional", [~w(a b c), ~w(a c)]))
    assert_sound(Bpmn.as_is("flower", [~w(d c a), ~w(a a), ~w(a d b a c)]))
  end

  test "the as-is of random logs is sound" do
    :rand.seed(:exsss, {4, 5, 6})

    for _round <- 1..60 do
      traces =
        for _trace <- 1..Enum.random(1..6),
            do: for(_step <- 1..Enum.random(1..6), do: Enum.random(~w(a b c d)))

      assert_sound(Bpmn.as_is("random", traces))
    end
  end

  test "the same log gives the same bytes" do
    traces = [~w(a b), ~w(a c b)]
    assert Bpmn.as_is("w", traces) == Bpmn.as_is("w", traces)
  end

  test "names are escaped" do
    xml = Bpmn.as_is("a<b & \"c\"", [["x<y"]]) |> assert_sound()
    assert xml =~ "a&lt;b &amp; &quot;c&quot;"
    assert xml =~ "x&lt;y (1)"
  end
end
