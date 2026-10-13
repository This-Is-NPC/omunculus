pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import "kit/ui"

// AgentsView is the conversation's agents at work, in one view. You sit on
// top, with the workspace they work in; below, a band per depth holds the
// works, each under the one it came from, and the agents configured at that
// depth with nothing to do, hollow. A link flows while the agent below runs.
// What an agent asked and still waits for is an arrow from it to whoever
// decides, named after what it asked. Picking a node opens it beside the map:
// to answer what it asked, read what it did, and write to it.
Item {
  id: view

  // The node picked: a work id, "" for the root agent's own conversation, or
  // null for none.
  property var picked: null
  signal leave()

  function pick(key) { picked = key }

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

  // The nodes: {key, parent, agent, title, depth, idle}. The root agent's own
  // conversation shows when nothing was opened for it or something waits on it.
  readonly property var nodes: {
    const works = Omunculus.tree("", false).map(row => ({
      key: row.work.id, parent: row.work.parent_id || null, agent: row.work.assignee || "", title: row.work.title, depth: row.level, idle: false
    }))
    const top = works.filter(node => node.depth === 0).length === 0
      || Omunculus.asked("").length > 0 || Omunculus.unreadFrom("").length > 0
      ? [{ key: "", parent: null, agent: rootAgent, title: Omunculus.title, depth: 0, idle: false }] : []
    const placed = top.concat(works)
    const idle = (Omunculus.setup ? Omunculus.setup.agents : [])
      .filter(agent => !agent.workflow_only && !placed.some(node => node.depth === agent.depth && node.agent === agent.name))
      .map(agent => ({ key: "idle:" + agent.name, parent: null, agent: agent.name, title: "", depth: agent.depth, idle: true }))
    return placed.concat(idle)
  }

  readonly property int nodeWidth: 200
  readonly property int nodeHeight: 66
  readonly property int across: 24
  readonly property int down: 70
  readonly property int youHeight: 54

  // Where each node sits: leaves side by side in tree order, a parent centred
  // over its children, the idle ones after the rest of their band.
  readonly property var places: {
    const at = {}
    const children = {}
    for (const node of nodes)
      if (node.parent !== null && !node.idle)
        (children[node.parent] = children[node.parent] || []).push(node.key)
    let slot = 0
    const lay = key => {
      const kids = children[key] || []
      if (kids.length === 0)
        return at[key] = slot++
      const spots = kids.map(lay)
      return at[key] = (spots[0] + spots[spots.length - 1]) / 2
    }
    nodes.filter(node => node.depth === 0 && !node.idle).forEach(node => lay(node.key))
    const bands = {}
    for (const node of nodes)
      if (at[node.key] !== undefined)
        bands[node.depth] = Math.max(bands[node.depth] ?? -1, at[node.key])
    for (const node of nodes.filter(node => node.idle))
      at[node.key] = bands[node.depth] = (bands[node.depth] ?? -1) + 1
    const result = {}
    for (const node of nodes)
      result[node.key] = {
        x: at[node.key] * (nodeWidth + across),
        y: youHeight + down + node.depth * (nodeHeight + down)
      }
    return result
  }
  readonly property real wide: Math.max(nodeWidth, ...Object.values(places).map(place => place.x + nodeWidth))
  readonly property real tall: youHeight + down + Math.max(0, ...nodes.map(node => node.depth)) * (nodeHeight + down) + nodeHeight
  readonly property real youX: {
    const tops = nodes.filter(node => node.depth === 0 && !node.idle).map(node => places[node.key].x)
    return tops.length === 0 ? 0 : (Math.min(...tops) + Math.max(...tops)) / 2
  }

  // The requests still waiting, as arrows from the asking node to whoever decides.
  readonly property var arrows: Omunculus.asking.map(request => {
    const from = places[request.work_id || ""]
    const work = Omunculus.work(request.work_id || "")
    const human = request.arbiter === "human"
    const target = human ? { x: youX, y: 0 } : places[work && work.parent_id ? work.parent_id : ""]
    if (!from || !target)
      return null
    let wanted = ""
    for (const option of Object.keys(request.options || {}))
      for (const step of request.options[option])
        if (step.name === "grant" && !wanted)
          wanted = step.args.name
    return {
      x1: from.x + nodeWidth * 0.78, y1: from.y,
      x2: target.x + nodeWidth * 0.78, y2: target.y + (human ? youHeight : nodeHeight),
      human: human, label: wanted
    }
  }).filter(arrow => arrow !== null)

  Keys.onEscapePressed: event => {
    if (picked !== null)
      picked = null
    else
      leave()
  }

  RowLayout {
    anchors.fill: parent
    spacing: 14

    Flickable {
      id: map
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      contentWidth: Math.max(width, canvas.width + 40)
      contentHeight: Math.max(height, canvas.height + 40)

      Item {
        id: canvas
        x: Math.max(20, (map.width - width) / 2)
        y: 20
        width: view.wide
        height: view.tall

        // Depth labels at the left of each band.
        Repeater {
          model: Array.from(new Set(view.nodes.map(node => node.depth))).sort()
          delegate: Label {
            required property int modelData
            x: -canvas.x + 4
            y: view.youHeight + view.down + modelData * (view.nodeHeight + view.down) - 18
            text: "DEPTH " + modelData
            color: Theme.line
            font.pixelSize: 9
            font.letterSpacing: 3
          }
        }

        // Links: you to the top band, each work to the one it came from.
        Repeater {
          model: view.nodes.filter(node => !node.idle)
          delegate: Shape {
            id: link
            required property var modelData
            readonly property var to: view.places[modelData.key] || { x: 0, y: 0 }
            readonly property var from: modelData.parent === null ? { x: view.youX, y: 0, you: true } : view.places[modelData.parent]
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
            anchors { fill: parent; margins: 8; leftMargin: 12; rightMargin: 12 }
            spacing: 4
            Label { text: "YOU"; color: Theme.primary; font.pixelSize: 10; font.letterSpacing: 3 }
            Label {
              Layout.fillWidth: true
              readonly property var place: Omunculus.workspaceOf("")
              text: (place.name ? place.name + "  ·  " : "") + place.root
              color: Theme.dim
              font.pixelSize: 10
              elide: Text.ElideMiddle
            }
          }
        }

        Repeater {
          model: view.nodes
          delegate: AgentNode {
            required property var modelData
            // A node may be asked for before the places follow a change in nodes.
            readonly property var place: view.places[modelData.key] || { x: 0, y: 0 }
            x: place.x
            y: place.y
            key: modelData.idle ? "" : modelData.key
            agent: modelData.agent
            title: modelData.title
            idle: modelData.idle
            selected: !modelData.idle && view.picked === modelData.key
            onChosen: view.pick(modelData.key)
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
                font.pixelSize: 9
                font.letterSpacing: 1
              }
            }
          }
        }
      }
    }

    AgentInspector {
      id: inspector
      Layout.preferredWidth: Math.min(400, view.width * 0.45)
      Layout.fillHeight: true
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
}
