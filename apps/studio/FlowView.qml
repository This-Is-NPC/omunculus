pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "kit/ui"

// FlowView draws a project as it runs, as a flowchart on a canvas without
// edges: you at the top, then each depth a row, where each workflow a work
// there may go through is a chain of its stages and each agent a work may
// go to stands on its own; a line runs from every agent that hands works
// down to every place a work below it may go. Each workspace is a zone of
// its own. Dragging moves the canvas, the wheel zooms it around the pointer;
// picking a node opens the agent beside the canvas.
Item {
  id: flow

  // The project drawn: its id, its overview, and the packs it imports.
  property string projectId: Studio.project
  readonly property var overview: Studio.overviews[projectId] || null
  readonly property var packs: Studio.packsOf[projectId] || []
  // Room the rail and the command bar take over the canvas, kept clear when it fits.
  property real leftInset: 0
  property real topInset: 0
  property real bottomInset: 0

  readonly property real zoomLevel: canvas.zoomLevel
  readonly property var picked: chart.nodes.find(node => node.id === pickedId) || null
  property string pickedId: ""

  signal agentPicked(string name)

  readonly property real nodeWidth: 290
  readonly property real nodeHeight: 132
  readonly property real stageGap: 40
  readonly property real flowGap: 72
  readonly property real rowGap: 110
  readonly property real labelWidth: 230

  // The pack each agent and workflow comes from.
  readonly property var origins: {
    const origins = { agents: {}, workflows: {} }
    for (const pack of packs || []) {
      pack.agents.forEach(name => origins.agents[name] = pack.name)
      pack.workflows.forEach(name => origins.workflows[name] = pack.name)
    }
    return origins
  }

  // Whether an agent hands works down: it has work or delegate.
  function hands(agent) {
    return agent.tools.some(tool => tool.state === "have" && ["work", "delegate"].some(name => tool.name === name || (tool.members || []).includes(name)))
  }

  // The flowchart laid out in canvas coordinates: zones (workspaces), rows
  // (depths), groups (workflows), nodes and edges.
  readonly property var chart: {
    const chart = { zones: [], rows: [], groups: [], nodes: [], edges: [], width: 0, height: 0 }
    if (!overview || overview.error)
      return chart
    let y = 0
    let order = 0
    const add = node => { node.order = order++; chart.nodes.push(node); return node }
    for (const place of overview.places) {
      const key = place.workspace || "root"
      const zoneTop = y
      y += 104
      const you = add({ id: key + "/you", kind: "person", x: labelWidth, y: y, width: nodeWidth, height: nodeHeight })
      // What hands works down from the row above, and where they arrive in
      // this one: a free agent's box, or a whole workflow's frame.
      let above = [you]
      y += nodeHeight + rowGap
      let right = labelWidth + nodeWidth
      for (const entry of place.depths.slice().sort((a, b) => a.depth - b.depth)) {
        const rowTop = y
        let x = labelWidth
        const here = []
        for (const workflow of entry.workflows) {
          const start = x
          const id = key + "/" + entry.depth + "/" + workflow.name
          let previous = null
          let handing = false
          workflow.stages.forEach((stage, index) => {
            const node = add({
              id: id + "/" + index, kind: "stage", x: x, y: rowTop, width: nodeWidth, height: nodeHeight,
              agent: stage.agent, stage: stage.name, index: index, workflow: workflow.name, group: id,
              pack: origins.agents[stage.agent.name] || ""
            })
            if (previous)
              chart.edges.push({ from: previous, to: node, kind: "chain" })
            handing = handing || hands(stage.agent)
            previous = node
            x += nodeWidth + stageGap
          })
          const group = {
            id: id, x: start - 16, y: rowTop - 42, width: x - stageGap - start + 32, height: nodeHeight + 58,
            name: workflow.name, required: workflow.required, pack: origins.workflows[workflow.name] || "", handing: handing
          }
          chart.groups.push(group)
          here.push(group)
          x += flowGap - stageGap
        }
        for (const agent of entry.agents) {
          here.push(add({
            id: key + "/" + entry.depth + "/" + agent.name, kind: "agent", x: x, y: rowTop, width: nodeWidth, height: nodeHeight,
            agent: agent, pack: origins.agents[agent.name] || "", handing: hands(agent)
          }))
          x += nodeWidth + stageGap
        }
        for (const from of above.filter(box => box.kind === "person" || box.handing))
          for (const to of here)
            chart.edges.push({ from: from, to: to, kind: from.kind === "person" ? "talk" : "down" })
        chart.rows.push({ depth: entry.depth, y: rowTop, changed: entry.changed, zone: key })
        right = Math.max(right, x - stageGap)
        above = here
        y += nodeHeight + rowGap
      }
      chart.zones.push({ place: place, key: key, x: 0, y: zoneTop, width: right + 48, height: y - rowGap + 48 - zoneTop })
      chart.width = Math.max(chart.width, right + 48)
      y += 60
    }
    chart.height = y
    return chart
  }

  // Its framing and zoom, as the canvas does them.
  function fit() { canvas.fit() }
  function zoomIn() { canvas.zoomIn() }
  function zoomOut() { canvas.zoomOut() }
  function actualSize() { canvas.actualSize() }
  function bringIntoView(node) { canvas.bringIntoView(node) }
  onPickedChanged: if (picked) Qt.callLater(() => canvas.bringIntoView(picked))

  // Coming back to the flow decodes it again and sweeps it.
  function reveal(item) {
    for (const child of item.children || []) {
      if (child.revealOnStage && child.replay)
        child.replay()
      reveal(child)
    }
  }
  onVisibleChanged: if (visible) { reveal(canvas.world); sweep.restart() }

  property bool fitted: false
  onChartChanged: if (!fitted && chart.nodes.length > 0) { fitted = true; Qt.callLater(fit); sweep.restart() }
  onProjectIdChanged: { fitted = false; pickedId = "" }

  FlowCanvas {
    id: canvas
    anchors.fill: parent
    contentWidth: flow.chart.width
    contentHeight: flow.chart.height
    leftInset: flow.leftInset
    topInset: flow.topInset
    bottomInset: flow.bottomInset
    rightInset: inspector.open ? inspector.width + 20 : 0
    onBackgroundClicked: flow.pickedId = ""
    onFramed: if (flow.picked) canvas.bringIntoView(flow.picked)

    // Each workspace's zone, with its strip: name, folder, its own lists.
    Repeater {
      model: flow.chart.zones
      delegate: Item {
        id: zone
        required property var modelData
        readonly property var place: modelData.place
        x: modelData.x
        y: modelData.y
        width: modelData.width
        height: modelData.height
        Rectangle {
          anchors.fill: parent
          color: Qt.alpha(Theme.success, 0.035)
          border.color: Qt.alpha(Theme.success, 0.3)
        }
        Row {
          x: 28
          y: 26
          spacing: 16
          DecodeLabel { renderType: Text.CurveRendering; value: (zone.place.workspace || "project root").toUpperCase(); color: Theme.success; font.pixelSize: 18; font.letterSpacing: 5 }
          Label { renderType: Text.CurveRendering; text: zone.place.root; color: Theme.dim; font.pixelSize: 13 }
          Label { renderType: Text.CurveRendering; visible: zone.place.default; text: "DEFAULT"; color: Theme.success; font.pixelSize: 12; font.letterSpacing: 2 }
          Label { renderType: Text.CurveRendering; visible: zone.place.outside; text: "OUTSIDE THE PROJECT"; color: Theme.warning; font.pixelSize: 12; font.letterSpacing: 2 }
          Repeater {
            model: zone.place.layer ? [].concat(
              zone.place.layer.mode ? [{ name: zone.place.layer.mode, state: "askable" }] : [],
              zone.place.layer.has.map(name => ({ name: name, state: "have" })),
              zone.place.layer.negotiable.map(name => ({ name: name, state: "askable" })),
              zone.place.layer.human.map(name => ({ name: name, state: "sealed" })),
              zone.place.layer.deny.map(name => ({ name: name, state: "blocked" }))) : []
            delegate: ToolChip {
              required property var modelData
              tool: modelData
            }
          }
        }
      }
    }

    // Each depth's label, in the column left of its row.
    Repeater {
      model: flow.chart.rows
      delegate: Column {
        required property var modelData
        x: 28
        y: modelData.y + 10
        spacing: 6
        Label { renderType: Text.CurveRendering; text: "DEPTH"; color: Theme.dim; font.pixelSize: 12; font.letterSpacing: 3 }
        DecodeLabel { renderType: Text.CurveRendering; value: String(modelData.depth).padStart(2, "0"); color: Theme.primary; font.pixelSize: 44; font.letterSpacing: 2 }
        Label {
          renderType: Text.CurveRendering
          text: modelData.depth === 0 ? "talks with you" : "handed down from " + (modelData.depth - 1)
          color: Theme.dim
          font.pixelSize: 13
        }
        Label { renderType: Text.CurveRendering; visible: modelData.changed; text: "CHANGED HERE"; color: Theme.magenta; font.pixelSize: 12; font.letterSpacing: 2 }
      }
    }

    // Each workflow's frame, named above its stages.
    Repeater {
      model: flow.chart.groups
      delegate: Item {
        required property var modelData
        x: modelData.x
        y: modelData.y
        width: modelData.width
        height: modelData.height
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.color: Qt.alpha(Theme.secondary, 0.35)
        }
        Row {
          x: 14
          y: 10
          spacing: 12
          Label { renderType: Text.CurveRendering; text: "WORKFLOW"; color: Theme.dim; font.pixelSize: 12; font.letterSpacing: 2.5 }
          DecodeLabel { renderType: Text.CurveRendering; value: modelData.name.toUpperCase(); color: Theme.secondary; font.pixelSize: 14; font.letterSpacing: 2.5 }
          Label { renderType: Text.CurveRendering; visible: modelData.required; text: "REQUIRED"; color: Theme.warning; font.pixelSize: 12; font.letterSpacing: 2 }
          Label { renderType: Text.CurveRendering; visible: modelData.pack !== ""; text: "◆ " + modelData.pack.toUpperCase(); color: Theme.magenta; font.pixelSize: 12; font.letterSpacing: 2 }
        }
      }
    }

    // The lines: a stage to the next, solid; you and every agent that hands
    // works down to where a work below may go, dashed and flowing downwards.
    Repeater {
      model: flow.chart.edges
      delegate: Shape {
        id: line
        required property var modelData
        readonly property bool chain: modelData.kind === "chain"
        // Lit when it touches the node picked, or the workflow it is a stage of.
        readonly property var near: flow.picked ? [flow.picked.id, flow.picked.group] : []
        readonly property bool lit: near.includes(modelData.from.id) || near.includes(modelData.to.id)
        readonly property real x1: chain ? modelData.from.x + modelData.from.width : modelData.from.x + modelData.from.width / 2
        readonly property real y1: chain ? modelData.from.y + modelData.from.height / 2 : modelData.from.y + modelData.from.height
        readonly property real x2: chain ? modelData.to.x : modelData.to.x + modelData.to.width / 2
        readonly property real y2: chain ? modelData.to.y + modelData.to.height / 2 : modelData.to.y
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        opacity: flow.pickedId === "" || lit ? 1 : 0.25
        Behavior on opacity { NumberAnimation { duration: 200 } }
        ShapePath {
          id: path
          strokeColor: line.chain ? Qt.alpha(Theme.secondary, 0.8) : line.lit ? Theme.primary
            : line.modelData.kind === "talk" ? Qt.alpha(Theme.primary, 0.55) : Qt.alpha(Theme.foreground, 0.28)
          strokeWidth: line.lit ? 3 : 2
          fillColor: "transparent"
          strokeStyle: line.chain ? ShapePath.SolidLine : ShapePath.DashLine
          dashPattern: [5, 4]
          startX: line.x1
          startY: line.y1
          PathCubic {
            x: line.x2
            y: line.y2
            control1X: line.chain ? (line.x1 + line.x2) / 2 : line.x1
            control1Y: line.chain ? line.y1 : (line.y1 + line.y2) / 2
            control2X: line.chain ? (line.x1 + line.x2) / 2 : line.x2
            control2Y: line.chain ? line.y2 : (line.y1 + line.y2) / 2
          }
          NumberAnimation on dashOffset { running: !line.chain; from: 8; to: 0; duration: 700; loops: Animation.Infinite }
        }
        // The arrow's head where the line arrives.
        ShapePath {
          strokeColor: "transparent"
          fillColor: path.strokeColor
          startX: line.chain ? line.x2 : line.x2 - 4
          startY: line.chain ? line.y2 - 4 : line.y2 - 7
          PathLine { x: line.chain ? line.x2 + 1 : line.x2; y: line.chain ? line.y2 : line.y2 + 1 }
          PathLine { x: line.chain ? line.x2 - 7 : line.x2 + 4; y: line.chain ? line.y2 + 4 : line.y2 - 7 }
        }
      }
    }

    Repeater {
      model: flow.chart.nodes
      delegate: FlowNode {
        required property var modelData
        x: modelData.x
        y: modelData.y
        width: flow.nodeWidth
        height: flow.nodeHeight
        spec: modelData
        order: modelData.order
        picked: flow.pickedId === modelData.id
        onActiveFocusChanged: if (activeFocus) flow.bringIntoView(modelData)
        onChosen: {
          forceActiveFocus()
          flow.pickedId = flow.pickedId === modelData.id ? "" : modelData.id
        }
      }
    }
  }

  // A line of the accent sweeping down the canvas when a project is drawn.
  Rectangle {
    id: scan
    width: parent.width
    height: 1
    color: Theme.primary
    opacity: 0
    SequentialAnimation {
      id: sweep
      PropertyAction { target: scan; property: "opacity"; value: 0.8 }
      NumberAnimation { target: scan; property: "y"; from: flow.topInset; to: flow.height; duration: 900; easing.type: Easing.InOutQuad }
      NumberAnimation { target: scan; property: "opacity"; to: 0; duration: 200 }
    }
  }

  Label {
    anchors.centerIn: parent
    visible: !flow.overview || !!flow.overview.error
    text: !flow.overview ? (Studio.connected ? "reading the project" : "the server does not answer") : flow.overview.error || ""
    color: flow.overview ? Theme.warning : Theme.dim
  }

  // The agent picked, beside the canvas, as it runs in its place.
  Rectangle {
    id: inspector
    readonly property bool open: flow.picked !== null && !!flow.picked.agent
    anchors { right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: flow.topInset + 12; bottomMargin: flow.bottomInset; rightMargin: open ? 20 : -width - 20 }
    Behavior on anchors.rightMargin { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    // Away, it takes no keyboard.
    visible: open || anchors.rightMargin > -width - 20
    enabled: open
    width: Math.min(460, Math.max(300, parent.width * 0.4))
    color: Theme.background
    border.color: Theme.line

    ScrollPage {
      id: scroll
      anchors { fill: parent; margins: 16 }
      contentHeight: details.implicitHeight
      Column {
        id: details
        width: scroll.width
        spacing: 12
        Flow {
          width: parent.width
          spacing: 10
          Label {
            text: inspector.open && flow.picked.kind === "stage" ? "STAGE " + flow.picked.stage.toUpperCase() + " OF " + flow.picked.workflow.toUpperCase() : "AGENT"
            color: Theme.dim
            font.pixelSize: 9
            font.letterSpacing: 2.5
          }
          Label {
            visible: inspector.open && flow.picked.pack !== ""
            text: inspector.open ? "◆ FROM " + flow.picked.pack.toUpperCase() : ""
            color: Theme.magenta
            font.pixelSize: 9
            font.letterSpacing: 2
          }
        }
        // First, so it is in view on a short window.
        Row {
          spacing: 8
          TraceButton {
            visible: flow.projectId === Studio.project
            dense: true
            role: "action"
            icon: inspector.open && flow.picked.pack ? "enter" : "edit"
            text: inspector.open && flow.picked.pack ? "OPEN AGENT" : "EDIT AGENT"
            onClicked: flow.agentPicked(flow.picked.agent.name)
          }
          TraceButton {
            dense: true
            role: "action"
            icon: "close"
            text: "CLOSE"
            tip: "close  esc"
            onClicked: flow.pickedId = ""
          }
        }
        Loader {
          width: parent.width
          active: inspector.open
          sourceComponent: AgentCard {
            width: details.width
            agent: flow.picked.agent
            place: ""
            onPicked: if (flow.projectId === Studio.project) flow.agentPicked(agent.name)
          }
        }
      }
    }
  }
}
