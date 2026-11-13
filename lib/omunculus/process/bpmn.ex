defmodule Omunculus.Process.Bpmn do
  @moduledoc """
  BPMN 2.0 XML, with the BPMNDI layout bpmn.io draws from, of a workflow:

  - `to_be/2`, the workflow as the config declares it: a task for each
    stage, its documentation giving the agent, what the stage and the
    agent are granted and denied and the tool overrides that gate it;
  - `as_is/2`, the workflow as works went through it: the process tree
    `Omunculus.Process.Tree` mines from their stage sequences, a task for
    each stage with how often it was entered, an exclusive gateway for a
    choice and for a loop.

  Both are deterministic: the same config and log give the same bytes. The
  layout is block structured, left to right, every block's entry and exit on
  one line; a loop's way back runs below it.
  """

  alias Omunculus.Process.Tree

  @task {100, 80}
  @gateway 50
  @event 36
  @gap 40
  @lane 30
  @row 20
  @margin 40

  @doc "The BPMN of workflow `name` as `steps` declare it, with `agents` the config's."
  @spec to_be(String.t(), [map], map) :: String.t()
  def to_be(name, steps, agents) do
    labels =
      Map.new(steps, fn step ->
        {step.name, {"#{step.name} (#{step.agent})", gates(step, agents)}}
      end)

    encode(name, {:seq, Enum.map(steps, &{:leaf, &1.name})}, labels)
  end

  @doc "The BPMN of workflow `name` as the stage sequences `traces` went through it."
  @spec as_is(String.t(), [[String.t()]]) :: String.t()
  def as_is(name, traces) do
    visits = traces |> Enum.concat() |> Enum.frequencies()

    labels =
      Map.new(visits, fn {stage, count} ->
        {stage, {"#{stage} (#{count})", "entered #{count} times in #{length(traces)} works"}}
      end)

    encode(name, Tree.mine(traces), labels)
  end

  defp gates(step, agents) do
    agent = agents[step.agent]

    [
      "agent: #{step.agent} (depth #{agent.depth}, model #{agent.model})",
      list("the agent grants", agent.ceiling.granted),
      list("the stage grants", step.ceiling.granted),
      list("the stage denies", step.ceiling.deny),
      list(
        "tools gated by overrides",
        Map.keys(step.ceiling.overrides) ++ Map.keys(agent.ceiling.overrides)
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp list(_label, []), do: nil
  defp list(label, names), do: "#{label}: " <> Enum.join(Enum.sort(Enum.uniq(names)), ", ")

  defp encode(name, tree, labels) do
    {width, _height, cy} = if tree == :tau, do: {0, 0, 0}, else: size(tree)
    line = @margin + cy
    state = %{count: 0, nodes: [], flows: []}
    {state, start} = node(state, :start, nil, nil, @margin, line - div(@event, 2), @event, @event)
    inner = @margin + @event + @gap

    {state, last} =
      if tree == :tau do
        {state, start}
      else
        {state, entry, exit} = emit(state, tree, inner, @margin, labels)
        {link(state, start, entry, [right(start), left(entry)]), exit}
      end

    {state, finish} =
      node(state, :end, nil, nil, inner + width + @gap, line - div(@event, 2), @event, @event)

    state = link(state, last, finish, [right(last), left(finish)])
    render(name, state)
  end

  # Width, height and the line of entry and exit, measured from the top.
  defp size({:leaf, _}), do: {elem(@task, 0), elem(@task, 1), div(elem(@task, 1), 2)}

  defp size({:seq, children}) do
    sizes = Enum.map(children, &size/1)
    above = sizes |> Enum.map(&elem(&1, 2)) |> Enum.max()
    below = sizes |> Enum.map(fn {_w, h, cy} -> h - cy end) |> Enum.max()
    width = sizes |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    {width + @gap * (length(sizes) - 1), above + below, above}
  end

  defp size({:xor, children}) do
    rows = Enum.map(children, &row/1)
    height = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    height = height + @row * (length(rows) - 1)
    width = rows |> Enum.map(&elem(&1, 0)) |> Enum.max()
    {@gateway * 2 + @gap * 2 + width, height, div(height, 2)}
  end

  defp size({:loop, body, redo}) do
    {body_width, body_height, line} = body_size(body)
    {redo_width, redo_height, _} = redo_size(redo)

    {@gateway * 2 + @gap * 2 + max(body_width, redo_width),
     body_height + @lane + redo_height + redo_lane(redo), line}
  end

  defp row(:tau), do: {0, @gap, div(@gap, 2)}
  defp row(tree), do: size(tree)

  defp body_size(:tau), do: {0, @gateway, div(@gateway, 2)}
  defp body_size(tree), do: size(tree)

  defp redo_size(:tau), do: {0, 0, 0}
  defp redo_size(tree), do: size(tree)

  defp redo_lane(:tau), do: 0
  defp redo_lane(_tree), do: @lane

  defp emit(state, {:leaf, stage}, x, top, labels) do
    {name, documentation} = labels[stage]
    {width, height} = @task
    {state, task} = node(state, :task, name, documentation, x, top, width, height)
    {state, task, task}
  end

  defp emit(state, {:seq, children}, x, top, labels) do
    {_width, _height, line} = size({:seq, children})

    {state, first, last, _x} =
      Enum.reduce(children, {state, nil, nil, x}, fn child, {state, first, last, at} ->
        {width, _height, child_line} = size(child)
        {state, entry, exit} = emit(state, child, at, top + line - child_line, labels)
        state = if last, do: link(state, last, entry, [right(last), left(entry)]), else: state
        {state, first || entry, exit, at + width + @gap}
      end)

    {state, first, last}
  end

  defp emit(state, {:xor, children}, x, top, labels) do
    {width, _height, cy} = size({:xor, children})
    line = top + cy

    {state, split} =
      node(state, :gateway, nil, nil, x, line - div(@gateway, 2), @gateway, @gateway)

    {state, join} =
      node(
        state,
        :gateway,
        nil,
        nil,
        x + width - @gateway,
        line - div(@gateway, 2),
        @gateway,
        @gateway
      )

    {state, _top} =
      Enum.reduce(children, {state, top}, fn child, {state, row_top} ->
        {_width, height, child_line} = row(child)
        at = row_top + child_line

        state =
          if child == :tau do
            link(state, split, join, out_of(split, at, line) ++ into(join, at, line))
          else
            {state, entry, exit} = emit(state, child, x + @gateway + @gap, row_top, labels)
            state = link(state, split, entry, out_of(split, at, line) ++ [left(entry)])
            link(state, exit, join, [right(exit)] ++ into(join, at, line))
          end

        {state, row_top + height + @row}
      end)

    {state, split, join}
  end

  defp emit(state, {:loop, body, redo}, x, top, labels) do
    {width, height, line_from_top} = size({:loop, body, redo})
    {_w, body_height, _cy} = body_size(body)
    line = top + line_from_top
    middle = div(@gateway, 2)
    {state, join} = node(state, :gateway, nil, nil, x, line - middle, @gateway, @gateway)

    {state, split} =
      node(state, :gateway, nil, nil, x + width - @gateway, line - middle, @gateway, @gateway)

    inner = x + @gateway + @gap

    state =
      if body == :tau do
        link(state, join, split, [right(join), left(split)])
      else
        {state, entry, exit} = emit(state, body, inner, top, labels)
        state = link(state, join, entry, [right(join), left(entry)])
        link(state, exit, split, [right(exit), left(split)])
      end

    {emit_redo(
       state,
       redo,
       {join, split},
       %{
         x: inner,
         top: top + body_height + @lane,
         line: line,
         bottom: top + height - div(@lane, 2),
         middle: top + body_height + div(@lane, 2)
       },
       labels
     ), join, split}
  end

  # The way back from the loop's split to its join: below the body, through
  # the redo when it has one.
  defp emit_redo(state, :tau, {join, split}, at, _labels) do
    back = [
      {split.x + div(@gateway, 2), at.line + div(@gateway, 2)},
      {split.x + div(@gateway, 2), at.middle},
      {join.x + div(@gateway, 2), at.middle},
      {join.x + div(@gateway, 2), at.line + div(@gateway, 2)}
    ]

    link(state, split, join, back)
  end

  defp emit_redo(state, redo, {join, split}, at, labels) do
    {_width, _height, redo_line} = size(redo)
    {state, entry, exit} = emit(state, redo, at.x, at.top, labels)
    redo_y = at.top + redo_line
    half = div(@gateway, 2)
    out_x = exit.x + exit.w + div(@gap, 2)

    state =
      link(state, split, entry, [
        {split.x + half, at.line + half},
        {split.x + half, at.middle},
        {entry.x - div(@gap, 2), at.middle},
        {entry.x - div(@gap, 2), redo_y},
        left(entry)
      ])

    link(state, exit, join, [
      right(exit),
      {out_x, redo_y},
      {out_x, at.bottom},
      {join.x + half, at.bottom},
      {join.x + half, at.line + half}
    ])
  end

  # Leaving a split, or entering a join, for the row at height `at`.
  defp out_of(split, at, line) do
    half = div(@gateway, 2)

    cond do
      at == line -> [right(split)]
      at < line -> [{split.x + half, split.y}, {split.x + half, at}]
      true -> [{split.x + half, split.y + @gateway}, {split.x + half, at}]
    end
  end

  defp into(join, at, line) do
    half = div(@gateway, 2)

    cond do
      at == line -> [left(join)]
      at < line -> [{join.x + half, at}, {join.x + half, join.y}]
      true -> [{join.x + half, at}, {join.x + half, join.y + @gateway}]
    end
  end

  defp left(node), do: {node.x, node.y + div(node.h, 2)}
  defp right(node), do: {node.x + node.w, node.y + div(node.h, 2)}

  defp node(state, kind, name, documentation, x, y, w, h) do
    count = state.count + 1

    node = %{
      id: "#{prefix(kind)}_#{count}",
      kind: kind,
      name: name,
      doc: documentation,
      x: x,
      y: y,
      w: w,
      h: h
    }

    {%{state | count: count, nodes: [node | state.nodes]}, node}
  end

  defp prefix(:start), do: "StartEvent"
  defp prefix(:end), do: "EndEvent"
  defp prefix(:task), do: "Activity"
  defp prefix(:gateway), do: "Gateway"

  defp link(state, from, to, points) do
    count = state.count + 1
    flow = %{id: "Flow_#{count}", from: from.id, to: to.id, points: points}
    %{state | count: count, flows: [flow | state.flows]}
  end

  defp render(name, state) do
    nodes = Enum.reverse(state.nodes)
    flows = Enum.reverse(state.flows)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI" xmlns:dc="http://www.omg.org/spec/DD/20100524/DC" xmlns:di="http://www.omg.org/spec/DD/20100524/DI" id="Definitions_1" targetNamespace="https://omunculus.dev/bpmn">
      <bpmn:process id="Process_1" name="#{escape(name)}" isExecutable="false">
    #{Enum.map_join(nodes, "\n", &element(&1, flows))}
    #{Enum.map_join(flows, "\n", &flow/1)}
      </bpmn:process>
      <bpmndi:BPMNDiagram id="BPMNDiagram_1">
        <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="Process_1">
    #{Enum.map_join(nodes, "\n", &shape/1)}
    #{Enum.map_join(flows, "\n", &edge/1)}
        </bpmndi:BPMNPlane>
      </bpmndi:BPMNDiagram>
    </bpmn:definitions>
    """
  end

  defp element(node, flows) do
    incoming = for flow <- flows, flow.to == node.id, do: flow.id
    outgoing = for flow <- flows, flow.from == node.id, do: flow.id
    tag = tag(node.kind)

    attrs =
      [~s(id="#{node.id}")] ++
        if(node.name, do: [~s(name="#{escape(node.name)}")], else: []) ++
        if(node.kind == :gateway,
          do: [~s(gatewayDirection="#{direction(incoming, outgoing)}")],
          else: []
        )

    body =
      [if(node.doc, do: "<bpmn:documentation>#{escape(node.doc)}</bpmn:documentation>")] ++
        Enum.map(incoming, &"<bpmn:incoming>#{&1}</bpmn:incoming>") ++
        Enum.map(outgoing, &"<bpmn:outgoing>#{&1}</bpmn:outgoing>")

    "    <bpmn:#{tag} #{Enum.join(attrs, " ")}>\n" <>
      Enum.map_join(Enum.reject(body, &is_nil/1), "", &"      #{&1}\n") <> "    </bpmn:#{tag}>"
  end

  defp tag(:start), do: "startEvent"
  defp tag(:end), do: "endEvent"
  defp tag(:task), do: "task"
  defp tag(:gateway), do: "exclusiveGateway"

  defp direction([_], [_, _ | _]), do: "Diverging"
  defp direction([_, _ | _], [_]), do: "Converging"
  defp direction(_incoming, _outgoing), do: "Mixed"

  defp flow(flow),
    do:
      ~s(    <bpmn:sequenceFlow id="#{flow.id}" sourceRef="#{flow.from}" targetRef="#{flow.to}" />)

  defp shape(node) do
    marker = if node.kind == :gateway, do: ~s( isMarkerVisible="true"), else: ""

    """
        <bpmndi:BPMNShape id="#{node.id}_di" bpmnElement="#{node.id}"#{marker}>
          <dc:Bounds x="#{node.x}" y="#{node.y}" width="#{node.w}" height="#{node.h}" />
        </bpmndi:BPMNShape>\
    """
  end

  defp edge(flow) do
    points =
      Enum.map_join(flow.points, "\n", fn {x, y} ->
        ~s(      <di:waypoint x="#{x}" y="#{y}" />)
      end)

    """
        <bpmndi:BPMNEdge id="#{flow.id}_di" bpmnElement="#{flow.id}">
    #{points}
        </bpmndi:BPMNEdge>\
    """
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
