pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "kit/client/Requests.js" as Requests
import "kit/ui"

// AgentsView is the conversation's agents at work, as a flowchart on a
// canvas that moves and zooms, as the studio's flow does. You sit on top,
// with the workspace they work in; below, a row per depth, named at its left,
// holds the works, each under the one it came from, each card the agent's
// portrait and the work it is on, and the agents configured at that depth
// with nothing to do, hollow. A work that goes through a workflow is a lane
// of its stages, its card at the stage it is at. A link flows while the agent below runs. What
// an agent asked and still waits for is an arrow from it to whoever decides,
// named after what it asked. Picking a node opens it beside the map: to
// answer what it asked, read what it did, and write to it. A card the
// keyboard reaches comes into view; FIT (a chord of the bar) frames the whole map.
Item {
  id: view

  // The node picked: a work id, "" for the root agent's own conversation, or
  // null for none.
  property var picked: null
  signal leave()
  signal openLog(string work)

  // Activity.status's result, which the window keeps; null until it does.
  readonly property var activity: Omunculus.activity || null
  readonly property var rows: activity && activity.rows ? activity.rows : []
  // The map's text summary: who works, who waits, how many are idle.
  readonly property string now: {
    const names = states => rows.filter(row => states.includes(row.state)).map(row => row.agent.toLowerCase())
    const parts = []
    const working = names(["working"])
    const waiting = names(["waiting-you", "waiting-team"])
    const idle = rows.filter(row => row.state === "idle").length + nodes.filter(node => node.idle).length
    if (working.length > 0)
      parts.push("working " + working.join(", "))
    if (waiting.length > 0)
      parts.push("waiting " + waiting.join(", "))
    if (idle > 0)
      parts.push("idle " + idle)
    return "Now: " + (parts.length > 0 ? parts.join("; ") : "nothing is running")
  }

  function pick(key) { picked = key }

  function fit() { map.fit() }

  // Puts the keyboard in the picked node's composer, to write to it or,
  // `noting`, to leave it a note.
  function write(noting) { inspector.write(noting) }

  // Picks the first node with something waiting on you.
  function pickPending() {
    const asking = Omunculus.waiting[0]
    const note = Omunculus.unread[0]
    picked = asking ? asking.work_id || "" : note ? note.work_id || "" : picked
  }

  readonly property var rootAgent: {
    const top = Omunculus.runs.find(run => String(run.depth) === "0")
    if (top)
      return top.agent
    const configured = Omunculus.setup ? Omunculus.setup.agents.find(agent => agent.depth === 0 && !agent.workflow_only) : null
    return configured ? configured.name : ""
  }

  // The nodes: {key, parent, agent, title, depth, idle, lane, width}. The
  // root agent's own conversation shows when nothing was opened for it or
  // something waits on it.
  readonly property var nodes: {
    const works = Omunculus.tree("", false).map(row => {
      const lane = Omunculus.laneOf(row.work)
      return {
        key: row.work.id, parent: row.work.parent_id || null, agent: Omunculus.agentOf(row.work),
        title: row.work.title, depth: row.level, idle: false, lane: lane,
        width: lane ? lane.steps.length * nodeWidth + (lane.steps.length - 1) * stageGap + 2 * lanePad : nodeWidth
      }
    })
    const top = works.filter(node => node.depth === 0).length === 0
      || Omunculus.asked("").length > 0 || Omunculus.unreadFrom("").length > 0
      ? [{ key: "", parent: null, agent: rootAgent, title: Omunculus.title, depth: 0, idle: false, lane: null, width: nodeWidth }] : []
    const placed = top.concat(works)
    const idle = (Omunculus.setup ? Omunculus.setup.agents : [])
      .filter(agent => !agent.workflow_only && !placed.some(node => node.depth === agent.depth && node.agent === agent.name))
      .map(agent => ({ key: "idle:" + agent.name, parent: null, agent: agent.name, title: "Idle", depth: agent.depth, idle: true, lane: null, width: nodeWidth }))
    return placed.concat(idle)
  }

  readonly property int nodeWidth: 320
  readonly property int nodeHeight: 150
  readonly property int across: 40
  readonly property int down: 130
  // A lane's stages apart, its frame around them, and its name above them.
  readonly property int stageGap: 40
  readonly property int lanePad: 16
  readonly property int laneHead: 42
  readonly property int youHeight: 72
  // The column left of the rows, where each depth is named.
  readonly property int labelWidth: 190

  // Where each node sits, {x, y, width, card}: each subtree as wide as its
  // node or its children side by side, whichever is wider, the subtrees
  // side by side in tree order, a parent centred over its children within
  // its own, the idle ones after the rest of their band. `y` is the top of
  // the cards, a lane's frame rising above it; `card` is the left of the
  // work's own card, in a lane that of the stage it is at.
  readonly property var places: {
    const byKey = {}
    const children = {}
    for (const node of nodes)
      byKey[node.key] = node
    for (const node of nodes)
      if (node.parent !== null && byKey[node.parent] && !node.idle)
        (children[node.parent] = children[node.parent] || []).push(node.key)
    const span = {}
    const measure = key => {
      const kids = children[key] || []
      const row = kids.reduce((sum, kid) => sum + measure(kid), 0) + Math.max(0, kids.length - 1) * across
      return span[key] = Math.max(byKey[key].width, row)
    }
    const at = {}
    const lay = (key, left) => {
      const kids = children[key] || []
      const row = kids.reduce((sum, kid) => sum + span[kid], 0) + Math.max(0, kids.length - 1) * across
      let x = left + (span[key] - row) / 2
      const centres = kids.map(kid => {
        const spot = lay(kid, x)
        x += span[kid] + across
        return spot + byKey[kid].width / 2
      })
      const own = byKey[key].width
      const centre = centres.length > 0 ? (centres[0] + centres[centres.length - 1]) / 2 : left + span[key] / 2
      return at[key] = Math.max(left, Math.min(left + span[key] - own, centre - own / 2))
    }
    let left = labelWidth
    for (const node of nodes.filter(node => !node.idle && (node.parent === null || !byKey[node.parent]))) {
      measure(node.key)
      lay(node.key, left)
      left += span[node.key] + across
    }
    const bands = {}
    for (const node of nodes)
      if (at[node.key] !== undefined)
        bands[node.depth] = Math.max(bands[node.depth] ?? labelWidth - across, at[node.key] + node.width)
    for (const node of nodes.filter(node => node.idle)) {
      at[node.key] = (bands[node.depth] ?? labelWidth - across) + across
      bands[node.depth] = at[node.key] + node.width
    }
    const result = {}
    for (const node of nodes)
      result[node.key] = {
        x: at[node.key], y: youHeight + down + node.depth * (nodeHeight + down), width: node.width,
        card: at[node.key] + (node.lane ? lanePad + node.lane.at * (nodeWidth + stageGap) : 0)
      }
    return result
  }
  readonly property real wide: Math.max(labelWidth + nodeWidth, ...Object.values(places).map(place => place.x + place.width)) + 40
  readonly property real tall: youHeight + down + Math.max(0, ...nodes.map(node => node.depth)) * (nodeHeight + down) + nodeHeight + lanePad
  readonly property real youX: {
    const tops = nodes.filter(node => node.depth === 0 && !node.idle).map(node => places[node.key])
    return tops.length === 0 ? labelWidth
      : (Math.min(...tops.map(place => place.x)) + Math.max(...tops.map(place => place.x + place.width)) - nodeWidth) / 2
  }
  // The box of a node's own card on the map, in a lane the stage it is at.
  function cardOf(key) {
    const place = places[key]
    return place ? { x: place.card, y: canvas.y + place.y, width: nodeWidth, height: nodeHeight } : null
  }

  // The requests still waiting, as arrows from the asking node to whoever decides.
  readonly property var arrows: Omunculus.asking.map(request => {
    const from = places[request.work_id || ""]
    const work = Omunculus.work(request.work_id || "")
    const human = Requests.human(request.arbiter)
    const target = human ? { x: youX, y: 0 } : places[work && work.parent_id ? work.parent_id : ""]
    if (!from || !target)
      return null
    const wanted = Requests.granted(request)
    return {
      x1: from.card + nodeWidth * 0.78, y1: from.y,
      x2: (human ? target.x : target.card) + nodeWidth * 0.78, y2: target.y + (human ? youHeight : nodeHeight),
      human: human, label: wanted ? wanted.name : ""
    }
  }).filter(arrow => arrow !== null)

  Keys.onEscapePressed: event => {
    if (picked !== null)
      picked = null
    else
      leave()
  }

  // The item the keyboard reaches on the map comes into the room left of the
  // inspector, as its box in the map's coordinates.
  readonly property Item focused: Window.activeFocusItem
  onFocusedChanged: {
    for (let item = focused; item; item = item.parent) {
      if (item === map.world) {
        const at = focused.mapToItem(map.world, 0, 0)
        map.bringIntoView({ x: at.x, y: at.y, width: focused.width, height: focused.height })
        return
      }
    }
  }

  // Picking a node brings its card into the room left of the inspector, and
  // so does framing the map again, as it does when a work picked as its
  // conversation opens comes onto it.
  onPickedChanged: if (picked !== null && cardOf(picked)) Qt.callLater(() => map.bringIntoView(cardOf(picked)))

  // The team as a tree, then the map below it.
  TeamPanel {
    id: team
    anchors { left: parent.left; right: inspector.visible ? inspector.left : parent.right; top: parent.top; margins: 14 }
    height: Math.min(view.height * 0.4, 360)
    activity: view.activity
    onOpenLog: work => view.openLog(work)
  }

  Row {
    id: summary
    anchors { left: parent.left; right: parent.right; top: team.bottom; margins: 14 }
    spacing: 18
    Label { text: view.now; color: Theme.foreground; font.pixelSize: 12; width: Math.max(0, parent.width - legend.width - parent.spacing); elide: Text.ElideRight }
    Row {
      id: legend
      spacing: 14
      Repeater {
        model: [
          { word: "Working", tone: Theme.primary },
          { word: "Waiting", tone: Theme.warning },
          { word: "Idle", tone: Theme.dim }
        ]
        delegate: Row {
          required property var modelData
          spacing: 6
          Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 12; height: 12; color: "transparent"; border.color: parent.modelData.tone; border.width: 2 }
          Label { text: parent.modelData.word; color: Theme.dim; font.pixelSize: 11 }
        }
      }
    }
  }

  FlowCanvas {
    id: map
    anchors { left: parent.left; right: parent.right; top: summary.bottom; bottom: parent.bottom; topMargin: 8 }
    contentWidth: view.wide
    contentHeight: view.tall + 40
    rightInset: inspector.visible ? inspector.width + 14 : 0
    bottomInset: zoom.height + 16
    onBackgroundClicked: view.picked = null
    // Fitting never goes below the actual size, where the text stays at its
    // size; the canvas scrolls instead.
    onFramed: {
      if (world.scale < 1) {
        world.scale = 1
        world.x = leftInset + 20
        world.y = topInset + 20
      }
      if (view.picked !== null && view.cardOf(view.picked)) bringIntoView(view.cardOf(view.picked))
    }
    // A conversation is framed when it is drawn, and again as it grows,
    // until it is moved by hand.
    onContentWidthChanged: if (!moved) Qt.callLater(fit)
    onContentHeightChanged: if (!moved) Qt.callLater(fit)

    Item {
      id: canvas
      x: 0
      y: 20
      width: view.wide
      height: view.tall

        // Each depth named at the left of its row.
        Repeater {
          model: Array.from(new Set(view.nodes.map(node => node.depth))).sort()
          delegate: Column {
            required property int modelData
            x: 20
            y: view.youHeight + view.down + modelData * (view.nodeHeight + view.down) + 10
            spacing: 4
            Label { text: "DEPTH"; color: Theme.dim; font.pixelSize: 11; font.letterSpacing: 2 }
            Label { text: String(modelData).padStart(2, "0"); color: Theme.primary; font.pixelSize: 36; font.letterSpacing: 2 }
          }
        }

        // Links: you to the top band, each work to the one it came from,
        // leaving a lane from the stage it is at and arriving at its frame.
        Repeater {
          model: view.nodes.filter(node => !node.idle)
          delegate: Shape {
            id: link
            required property var modelData
            readonly property var place: view.places[modelData.key] || { x: 0, y: 0, width: view.nodeWidth }
            readonly property var to: { "x": place.x + place.width / 2 - view.nodeWidth / 2, "y": place.y - (modelData.lane ? view.laneHead : 0) }
            readonly property var parentPlace: modelData.parent === null ? undefined : view.places[modelData.parent]
            readonly property var from: modelData.parent === null ? { x: view.youX, y: 0, you: true } : parentPlace ? { x: parentPlace.card, y: parentPlace.y } : undefined
            readonly property bool running: Omunculus.busy(modelData.key)
            anchors.fill: parent
            visible: from !== undefined
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: link.running ? Theme.primary : Theme.line
              strokeWidth: link.running ? 1.5 : 1
              fillColor: "transparent"
              strokeStyle: link.running ? ShapePath.DashLine : ShapePath.SolidLine
              dashPattern: [3, 3]
              startX: link.from ? link.from.x + view.nodeWidth / 2 : 0
              startY: link.from ? link.from.y + (link.from.you ? view.youHeight : view.nodeHeight) : 0
              PathCubic {
                x: link.to.x + view.nodeWidth / 2
                y: link.to.y
                control1X: link.from ? link.from.x + view.nodeWidth / 2 : 0
                control1Y: link.from ? link.from.y + (link.from.you ? view.youHeight : view.nodeHeight) + view.down / 2 : 0
                control2X: link.to.x + view.nodeWidth / 2
                control2Y: link.to.y - view.down / 2
              }
              // The dashes flow down to the agent while it runs.
              NumberAnimation on dashOffset {
                running: link.running
                loops: Animation.Infinite
                from: 6
                to: 0
                duration: 500
              }
            }
          }
        }

        // You, and where the agents work.
        Rectangle {
          x: view.youX
          y: 0
          width: view.nodeWidth
          height: view.youHeight
          color: Theme.background
          border.color: Omunculus.waiting.length > 0 ? Theme.warning : Theme.primary
          border.width: Omunculus.waiting.length > 0 ? 2 : 1
          ColumnLayout {
            anchors { fill: parent; margins: 10; leftMargin: 14; rightMargin: 14 }
            spacing: 4
            Label { text: "YOU"; color: Theme.primary; font.pixelSize: 18; font.letterSpacing: 4 }
            Label {
              Layout.fillWidth: true
              readonly property var place: Omunculus.workspaceOf("")
              text: (place.name ? place.name + "  ·  " : "") + place.root
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideMiddle
            }
          }
        }

        // Each node: a work's card, or its workflow's lane. Not a Loader,
        // whose focus scope would keep the cards out of the Tab chain.
        Repeater {
          model: view.nodes
          delegate: Item {
            id: slot
            required property var modelData
            // A node may be asked for before the places follow a change in nodes.
            readonly property var place: view.places[modelData.key] || { x: 0, y: 0 }
            x: place.x
            y: place.y - (modelData.lane ? view.laneHead : 0)

            Repeater {
              model: slot.modelData.lane ? [] : [slot.modelData]
              delegate: AgentNode {
                required property var modelData
                key: modelData.idle ? "" : modelData.key
                agent: modelData.agent
                title: modelData.title
                idle: modelData.idle
                selected: !modelData.idle && view.picked === modelData.key
                onChosen: view.pick(modelData.key)
              }
            }
            Repeater {
              model: slot.modelData.lane ? [slot.modelData] : []
              delegate: WorkflowLane {
                required property var modelData
                node: modelData
                cardWidth: view.nodeWidth
                cardHeight: view.nodeHeight
                gap: view.stageGap
                pad: view.lanePad
                head: view.laneHead
                selected: view.picked === modelData.key
                onChosen: view.pick(modelData.key)
              }
            }
          }
        }

        // What waits: an arrow from the asker to whoever decides, named.
        Repeater {
          model: view.arrows
          delegate: Item {
            id: arrow
            required property var modelData
            anchors.fill: parent
            readonly property color tone: modelData.human ? Theme.warning : Theme.dim
            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer
              ShapePath {
                strokeColor: arrow.tone
                strokeWidth: 1.5
                fillColor: "transparent"
                startX: arrow.modelData.x1
                startY: arrow.modelData.y1
                PathCubic {
                  x: arrow.modelData.x2
                  y: arrow.modelData.y2
                  control1X: arrow.modelData.x1 + 36
                  control1Y: arrow.modelData.y1 - view.down / 2
                  control2X: arrow.modelData.x2 + 36
                  control2Y: arrow.modelData.y2 + view.down / 2
                }
              }
            }
            Rectangle {
              x: arrow.modelData.x2 - 3
              y: arrow.modelData.y2 - 3
              width: 6
              height: 6
              radius: 3
              color: arrow.tone
            }
            Rectangle {
              visible: arrow.modelData.label !== ""
              x: (arrow.modelData.x1 + arrow.modelData.x2) / 2 + 30 - width / 2
              y: (arrow.modelData.y1 + arrow.modelData.y2) / 2 - height / 2
              width: tag.implicitWidth + 12
              height: 18
              color: Theme.background
              border.color: arrow.tone
              Label {
                id: tag
                anchors.centerIn: parent
                text: arrow.modelData.label
                color: arrow.tone
                font.pixelSize: 11
                font.letterSpacing: 1
              }
            }
          }
        }
      }
    }

  ZoomControl {
    id: zoom
    anchors { left: parent.left; bottom: parent.bottom }
    target: map
  }

  // The node picked, beside the map, over it.
  AgentInspector {
    id: inspector
    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
    width: Math.min(420, view.width * 0.45)
    visible: view.picked !== null
    key: view.picked === null ? "" : view.picked
    agent: {
      const node = view.nodes.find(item => item.key === view.picked)
      return node ? node.agent : ""
    }
    onClosed: view.picked = null
    onPicked: key => view.pick(key)
  }
}
