pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Tree.js" as Tree
import "kit/ui"

// NodeDetail is the PICKED WORK panel under the tree: the work's agent (its
// dot and name), its level and parent, its title, its stages, its state and,
// while it waits on someone, what for. OPEN THREAD, filled, is the page's one
// main action; LOG and COST open those pages. No figures here: the cost is
// shown only in COST.
SurfaceFrame {
  id: panel

  // The Progress node of the work picked, or null for none.
  property var node: null
  // Its parent's node, or null for a root.
  property var parentNode: null
  signal threadWanted()
  signal logWanted()
  signal costWanted()

  readonly property var look: node ? Tree.stateOf(node) : null
  // What it waits for: the question it asked, in its first line.
  readonly property string reason: node && node.asks.length > 0 ? Progress.firstLine(node.asks[0].question) : ""

  implicitHeight: content.implicitHeight + Theme.space.inset * 2
  variant: "filled"
  tone: Theme.primary

  ColumnLayout {
    id: content
    x: Theme.space.inset
    y: Theme.space.inset
    width: parent.width - Theme.space.inset * 2
    spacing: Theme.space.gap

    Kicker { Layout.fillWidth: true; text: "Picked work" }

    Label {
      visible: !panel.node
      Layout.fillWidth: true
      text: "Pick a work to see it here."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
    }

    Flow {
      visible: !!panel.node
      Layout.fillWidth: true
      spacing: Theme.space.gap
      AgentName { name: panel.node ? panel.node.agent : ""; tone: panel.node ? Omunculus.toneOf(panel.node.agent) : Theme.dim }
      Label {
        text: panel.node ? "level " + (panel.node.level + 1) + (panel.parentNode ? ", under " + panel.parentNode.agent : "") : ""
        color: Theme.dim
        font.pixelSize: Theme.type.log.size
      }
    }
    Label {
      visible: !!panel.node
      Layout.fillWidth: true
      text: panel.node ? panel.node.title : ""
      color: Theme.foreground
      font.pixelSize: Theme.type.cardBody.size
      font.bold: true
      wrapMode: Text.Wrap
    }
    StagePath { Layout.fillWidth: true; stages: panel.node ? panel.node.steps : [] }
    RowLayout {
      visible: !!panel.node
      Layout.fillWidth: true
      spacing: Theme.space.gap
      StateMark { state: panel.look ? panel.look.state : ""; text: panel.look ? panel.look.text : "" }
      Label {
        visible: panel.reason !== ""
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: Theme.type.meta.separator.trim() + "  " + panel.reason
        color: Theme.dim
        font.pixelSize: Theme.type.log.size
        elide: Text.ElideRight
      }
    }

    Flow {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      TraceButton { role: "primary"; filled: true; dense: true; text: "OPEN THREAD"; enabled: !!panel.node; tip: "the work's own thread"; onClicked: panel.threadWanted() }
      TraceButton { role: "action"; dense: true; text: "LOG"; enabled: !!panel.node; tip: "the events of this work"; onClicked: panel.logWanted() }
      TraceButton { role: "action"; dense: true; text: "COST"; enabled: !!panel.node; tip: "what this work used"; onClicked: panel.costWanted() }
    }
  }
}
