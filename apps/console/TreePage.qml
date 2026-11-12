pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Tree.js" as Tree
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TreePage is the TREE page: where the conversation is in its workflow (the
// stage path of its first work, StagePath), a CHART | OUTLINE toggle, the
// agents by level and, under them, the work picked. The chart (TreeChart)
// draws a band per level with a node per agent, connectors and a bracket
// under works that ran at once; the outline (TreeOutline) is the same tree as
// lineage rows, the default on a phone. A node or row picks its work; the
// PICKED WORK panel (NodeDetail) opens its thread, its log or its cost. ↑/↓
// pick the work before or after, Enter opens its thread, Esc leaves.
FocusScope {
  id: team

  // The work picked, or "" for none.
  property string picked: ""
  // "chart", "outline", or "" for the width's own.
  property string layout: ""
  signal leave()
  signal openLog(string work)
  signal openThread(string work)
  signal openCost()

  readonly property var progress: Omunculus.progress
  readonly property var flat: progress ? progress.flat : []
  readonly property var byWork: Tree.index(flat)
  readonly property var pickedNode: byWork[picked] || null
  readonly property string shape: layout !== "" ? layout : Breakpoints.size(width) === "narrow" ? "outline" : "chart"

  // The request waiting on you nearest the work picked — its own, above it,
  // below it — else the newest.
  function nearestForYou() {
    const human = node => node.asks.filter(ask => ask.forYou).map(ask => ask.id)
    for (let at = pickedNode; at; at = byWork[at.parent])
      if (human(at).length > 0)
        return human(at)[0]
    const below = pickedNode ? flat.filter(node => {
      for (let at = node; at; at = byWork[at.parent])
        if (at === pickedNode)
          return true
      return false
    }) : []
    for (const node of below)
      if (human(node).length > 0)
        return human(node)[0]
    const newest = progress ? progress.forYou[progress.forYou.length - 1] : null
    return newest ? newest.id : ""
  }

  // Moves the pick to the work before (-1) or after (1) in the tree's order.
  function move(by) {
    const at = flat.findIndex(node => node.work === picked)
    const to = at < 0 ? 0 : Math.max(0, Math.min(flat.length - 1, at + by))
    if (flat.length > 0)
      picked = flat[to].work
  }

  Keys.onEscapePressed: leave()
  Keys.onUpPressed: move(-1)
  Keys.onDownPressed: move(1)
  Keys.onReturnPressed: if (picked !== "") openThread(picked)

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      StagePath {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        size: Theme.type.cardBody.size
        stages: team.flat.length > 0 ? Progress.trail(team.flat, Omunculus.journeys, team.flat[0].work, Infinity) : []
      }
      Item { visible: team.flat.length === 0; Layout.fillWidth: true }
      Chip { text: "CHART"; checked: team.shape === "chart"; onClicked: team.layout = "chart" }
      Chip { text: "OUTLINE"; checked: team.shape === "outline"; onClicked: team.layout = "outline" }
    }

    Label {
      visible: team.flat.length === 0
      Layout.fillWidth: true
      text: team.progress === null ? "Reading the conversation." : "No work in this conversation yet."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }

    TreeChart {
      visible: team.flat.length > 0 && team.shape === "chart"
      Layout.fillWidth: true
      Layout.fillHeight: true
      picked: team.picked
      onChosen: work => team.picked = work
    }
    TreeOutline {
      visible: team.flat.length > 0 && team.shape === "outline"
      Layout.fillWidth: true
      Layout.fillHeight: true
      picked: team.picked
      onChosen: work => team.picked = work
      onOpened: work => team.openThread(work)
    }

    NodeDetail {
      Layout.fillWidth: true
      Layout.preferredHeight: implicitHeight
      node: team.pickedNode
      parentNode: team.pickedNode ? team.byWork[team.pickedNode.parent] || null : null
      onThreadWanted: team.openThread(team.picked)
      onLogWanted: team.openLog(team.picked)
      onCostWanted: team.openCost()
    }
  }
}
