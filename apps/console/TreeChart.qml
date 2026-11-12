pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as C
import "kit/client/Tree.js" as Tree
import "kit/ui"

// TreeChart is the conversation's agents as a chart (Tree.chart): a band per
// level, L0 for you and the agent that talks with you, then one for each level
// of works down, a node per agent (TreeNode), elbow connectors from each work
// to the works it handed down, and a bracket under works that ran at once
// ("PARALLEL ×4 · 2 DONE · 2 WORKING"), each node as wide as the longest name
// or state needs. It scrolls, with a bar, when wider than the page.
// A node chosen emits chosen(work); `picked` is the work picked.
Flickable {
  id: chart

  property string picked: ""
  signal chosen(string work)

  readonly property var layout: Tree.chart(Omunculus.progress)
  // The width the widest node needs, as measured by the nodes themselves.
  readonly property real nodeWidth: {
    let widest = 0
    for (let each = 0; each < nodes.count; each++)
      widest = Math.max(widest, nodes.itemAt(each) ? nodes.itemAt(each).wanted : 0)
    return widest
  }
  readonly property real nodeHeight: Theme.size.row + Theme.space.gap
  readonly property real colWidth: nodeWidth + Theme.space.gap * 2
  readonly property real bandHeight: nodeHeight + Theme.size.row
  readonly property real labelWidth: Theme.size.gutter * 2
  // A cell's box and the middle of the gap under its band, where its works' bus runs.
  readonly property var at: {
    const boxes = {}
    layout.cells.forEach(cell => {
      boxes[cell.key] = {
        x: labelWidth + cell.col * colWidth + (colWidth - nodeWidth) / 2,
        y: cell.level * bandHeight + Theme.space.gap
      }
    })
    return boxes
  }

  clip: true
  boundsBehavior: Flickable.StopAtBounds
  C.ScrollBar.horizontal: C.ScrollBar { policy: C.ScrollBar.AsNeeded }
  contentWidth: Math.max(width, labelWidth + layout.columns * colWidth)
  contentHeight: layout.levels * bandHeight
  flickableDirection: Flickable.HorizontalAndVerticalFlick

  // The level bands.
  Repeater {
    model: chart.layout.levels
    delegate: Item {
      id: band
      required property int index
      y: index * chart.bandHeight
      width: chart.contentWidth
      height: chart.bandHeight
      Label {
        x: Theme.space.tight
        y: Theme.space.gap
        text: "L" + band.index
        color: Theme.dim
        font.pixelSize: Theme.type.log.size
      }
      Rectangle { visible: band.index > 0; width: parent.width; height: 1; color: Theme.line }
    }
  }

  // The connectors: down from a work to a bus, along it, down to each work.
  Repeater {
    model: chart.layout.links
    delegate: Item {
      id: link
      required property var modelData
      readonly property var parentBox: chart.at[modelData.from]
      readonly property var boxes: modelData.to.map(key => chart.at[key])
      readonly property real busY: parentBox.y + chart.nodeHeight + (chart.bandHeight - chart.nodeHeight) / 2 - Theme.space.gap / 2
      readonly property real fromX: Math.min(parentBox.x, ...boxes.map(box => box.x)) + chart.nodeWidth / 2
      readonly property real toX: Math.max(parentBox.x, ...boxes.map(box => box.x)) + chart.nodeWidth / 2
      Rectangle { x: link.parentBox.x + chart.nodeWidth / 2; y: link.parentBox.y + chart.nodeHeight; width: 1; height: link.busY - y; color: Theme.faint }
      Rectangle { x: link.fromX; y: link.busY; width: link.toX - link.fromX + 1; height: 1; color: Theme.faint }
      Repeater {
        model: link.boxes
        delegate: Rectangle {
          required property var modelData
          x: modelData.x + chart.nodeWidth / 2
          y: link.busY
          width: 1
          height: modelData.y - link.busY
          color: Theme.faint
        }
      }
    }
  }

  // You and the agent that talks with you.
  Rectangle {
    visible: chart.layout.side !== null
    readonly property var from: chart.layout.side ? chart.at[chart.layout.side.from] : null
    readonly property var to: chart.layout.side ? chart.at[chart.layout.side.to] : null
    x: from ? from.x + chart.nodeWidth : 0
    y: from ? from.y + chart.nodeHeight / 2 : 0
    width: from && to ? to.x - x : 0
    height: 1
    color: Theme.faint
  }

  // The brackets of works that ran at once.
  Repeater {
    model: chart.layout.brackets
    delegate: Item {
      id: bracket
      required property var modelData
      readonly property real begin: chart.labelWidth + modelData.from * chart.colWidth + (chart.colWidth - chart.nodeWidth) / 2
      readonly property real end: chart.labelWidth + modelData.to * chart.colWidth + (chart.colWidth + chart.nodeWidth) / 2
      x: begin
      y: modelData.level * chart.bandHeight + chart.nodeHeight + Theme.space.gap + Theme.space.tight
      width: end - begin
      height: Theme.space.gap
      Rectangle { width: 1; height: parent.height; color: Theme.dim }
      Rectangle { x: parent.width - 1; width: 1; height: parent.height; color: Theme.dim }
      Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Theme.dim }
      Label {
        y: parent.height + Theme.space.line
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: bracket.modelData.summary
        color: Theme.dim
        font.pixelSize: Theme.type.header.size
        font.letterSpacing: Theme.type.header.tracking
        elide: Text.ElideRight
      }
    }
  }

  // The nodes.
  Repeater {
    id: nodes
    model: chart.layout.cells
    delegate: TreeNode {
      id: cell
      required property var modelData
      readonly property var look: modelData.kind === "work" ? Tree.stateOf(modelData.node) : modelData.kind === "front" ? Tree.frontState(modelData.front) : ({ state: "", text: "" })
      x: chart.at[modelData.key].x
      y: chart.at[modelData.key].y
      width: chart.nodeWidth
      agent: modelData.kind === "you" ? "you" : modelData.kind === "front" ? modelData.front.agent : modelData.node.agent
      agentTone: modelData.kind === "you" ? Theme.primary : Omunculus.toneOf(agent)
      state: look.state
      stateText: look.text
      picked: modelData.kind === "work" && chart.picked === modelData.key
      onChosen: if (modelData.kind === "work") chart.chosen(modelData.key)
    }
  }
}
