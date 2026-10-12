pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

// OrchestrationView is the conversation's agents at work, as one map: the
// root agent on the left and each work handed down to the right of the one it
// came from, joined by a curve that flows while its agent runs. Everything
// that waits hangs from the node that asked; clicking a node opens what its
// agent said and did. Larger than its room, it scrolls both ways.
Flickable {
  id: map

  // The root agent's thread or a work was picked.
  signal chosen(string work)

  // The nodes: the root agent's own, then every work in tree order.
  readonly property var nodes: {
    const top = Omunculus.runs.find(run => String(run.depth) === "0")
    return [{ key: "", parent: null, work: null, agent: top ? top.agent : "", title: Omunculus.title }]
      .concat(Omunculus.tree("", false).map(row => ({
        key: row.work.id, parent: row.work.parent_id || "", work: row.work, agent: row.work.assignee || "", title: row.work.title
      })))
  }
  // The curves between the nodes: {x1, y1, x2, y2, running, yours}.
  property var edges: []

  readonly property int column: 240 + 56
  readonly property int gap: 18

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  contentWidth: canvas.width
  contentHeight: canvas.height

  onNodesChanged: arrange()

  function arrange() { Qt.callLater(layout) }

  // Leaves stack down their column; a node sits level with its first child,
  // and the next node starts below whichever of them ends lower.
  function layout() {
    const items = {}
    const children = {}
    for (let i = 0; i < placed.count; i++) {
      const item = placed.itemAt(i)
      if (!item)
        return
      items[item.key] = item
      if (item.parentKey !== null)
        (children[item.parentKey] = children[item.parentKey] || []).push(item.key)
    }
    if (items[""] === undefined)
      return
    let cursor = 0
    let wide = 0
    const lay = (key, depth) => {
      const item = items[key]
      const start = cursor
      item.x = depth * column
      wide = Math.max(wide, item.x + item.width)
      for (const kid of children[key] || [])
        lay(kid, depth + 1)
      item.y = start
      cursor = Math.max(cursor, start + item.implicitHeight + gap)
    }
    lay("", 0)
    canvas.width = wide
    canvas.height = cursor
    edges = Object.values(items).filter(item => item.parentKey !== null && items[item.parentKey]).map(item => {
      const from = items[item.parentKey]
      return { x1: from.x + from.width, y1: from.y + 22, x2: item.x, y2: item.y + 22, running: item.running, yours: item.yours }
    })
  }

  // Brings the first node waiting on you into view.
  function reveal() {
    for (let i = 0; i < placed.count; i++) {
      const item = placed.itemAt(i)
      if (item && item.yours) {
        contentX = Math.max(0, Math.min(contentWidth - width, item.x - 24))
        contentY = Math.max(0, Math.min(contentHeight - height, item.y - 24))
        return
      }
    }
  }

  Item {
    id: canvas

    Repeater {
      model: map.edges
      delegate: Shape {
        id: edge
        required property var modelData
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          id: path
          strokeColor: edge.modelData.yours ? Theme.warning : edge.modelData.running ? Theme.primary : Theme.line
          strokeWidth: edge.modelData.running ? 1.5 : 1
          fillColor: "transparent"
          strokeStyle: edge.modelData.running ? ShapePath.DashLine : ShapePath.SolidLine
          dashPattern: [3, 3]
          startX: edge.modelData.x1
          startY: edge.modelData.y1
          PathCubic {
            x: edge.modelData.x2
            y: edge.modelData.y2
            control1X: edge.modelData.x1 + 40
            control1Y: edge.modelData.y1
            control2X: edge.modelData.x2 - 40
            control2Y: edge.modelData.y2
          }
          // The dashes flow from the parent to the child while it runs.
          NumberAnimation on dashOffset {
            running: edge.modelData.running
            loops: Animation.Infinite
            from: 6
            to: 0
            duration: 500
          }
        }
      }
    }

    Repeater {
      id: placed
      model: map.nodes
      onItemAdded: map.arrange()
      onItemRemoved: map.arrange()
      delegate: AgentNode {
        required property var modelData
        readonly property var parentKey: modelData.parent
        work: modelData.work
        agent: modelData.agent
        title: modelData.title
        onImplicitHeightChanged: map.arrange()
        onRunningChanged: map.arrange()
        onYoursChanged: map.arrange()
        onChosen: map.chosen(key)
      }
    }
  }
}
