import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// AgentNode is one agent on the conversation's map, a card of fixed size:
// its portrait, its name in its colour and the model it runs on, the work it
// is on, its state and the tool it is calling, and, in a workflow's lane,
// the stage that is its own. Its border is that state — running, waiting on
// you, broken, done — a ring keeps leaving the portrait while it runs, and a
// badge counts what it asked that still waits. A card that is no work shows
// hollow: an agent configured at that depth with nothing to do, or a stage
// of a lane the work went through, checked, or has ahead. The keyboard
// reaches a work's card; Enter or Space picks it.
Rectangle {
  id: node

  // The work, or "" for the root agent's own conversation.
  property string key: ""
  property string agent: ""
  property string title: ""
  // A card that is no work: an agent with nothing to do, or a stage of a
  // lane the work is not at.
  property bool idle: false
  // The stage of a lane it stands for, its place there, and whether the work
  // went through it.
  property string stage: ""
  property int stageIndex: 0
  property bool passed: false
  property bool selected: false
  signal chosen()

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property string workState: work ? work.state : "open"
  readonly property bool running: !idle && Omunculus.busy(key)
  readonly property var asks: idle ? [] : Omunculus.asked(key)
  readonly property int toYou: asks.filter(request => Requests.human(request.arbiter)).length + (idle ? 0 : Omunculus.unreadFrom(key).length)
  readonly property color agentTone: Omunculus.toneOf(agent)
  readonly property color stateTone: toYou > 0 ? Theme.warning
    : workState === "broken" ? Theme.error
    : running ? agentTone
    : Theme.line

  width: 320
  height: idle ? 100 : 150
  activeFocusOnTab: !idle
  Keys.onReturnPressed: chosen()
  Keys.onSpacePressed: chosen()
  color: selected ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.1)) : pointer.containsMouse ? Theme.highlight : Theme.background
  border.color: selected ? Theme.primary : passed ? Qt.alpha(Theme.success, 0.5) : stateTone
  border.width: selected || toYou > 0 || running ? 2 : 1
  opacity: passed ? 0.6 : workState === "done" || workState === "cancelled" ? 0.6 : 1
  Behavior on color { ColorAnimation { duration: 140 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }
  Behavior on opacity { NumberAnimation { duration: 200 } }

  Portrait {
    id: face
    x: node.border.width
    y: node.border.width
    width: node.height - 2 * node.border.width
    height: width
    agent: node.agent
    source: Omunculus.imageOf(node.agent)
    tone: Omunculus.toneOf(node.agent)
    initialSize: 44
    // A ring that keeps leaving the corner while the agent runs.
    Rectangle {
      id: ring
      x: parent.width - width / 2 - 10
      y: parent.height - height / 2 - 10
      width: 10
      height: 10
      radius: width / 2
      color: "transparent"
      border.color: node.agentTone
      border.width: 2
      visible: node.running
      ParallelAnimation {
        running: node.running
        loops: Animation.Infinite
        NumberAnimation { target: ring; property: "width"; from: 10; to: 34; duration: 1400; easing.type: Easing.OutCubic }
        NumberAnimation { target: ring; property: "height"; from: 10; to: 34; duration: 1400; easing.type: Easing.OutCubic }
        NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: 1400 }
      }
    }
    Rectangle {
      x: parent.width - 15
      y: parent.height - 15
      width: 10
      height: 10
      radius: 5
      visible: node.running
      color: node.agentTone
    }
  }

  ColumnLayout {
    anchors { left: face.right; right: parent.right; top: parent.top; bottom: parent.bottom; margins: 12 }
    spacing: 5

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.fillWidth: true
        text: node.agent
        color: node.agentTone
        font.pixelSize: 15
        font.letterSpacing: 1.5
        elide: Text.ElideRight
      }
      // What it asked that still waits: lit when any of it waits on you.
      Rectangle {
        visible: node.asks.length > 0 || node.toYou > 0
        implicitWidth: Math.max(implicitHeight, tally.implicitWidth + 8)
        implicitHeight: 17
        color: node.toYou > 0 ? Theme.warning : "transparent"
        border.color: node.toYou > 0 ? Theme.warning : Theme.dim
        Label {
          id: tally
          anchors.centerIn: parent
          text: Math.max(node.asks.length, node.toYou)
          color: node.toYou > 0 ? Theme.badgeForeground : Theme.dim
          font.pixelSize: 11
          font.bold: true
        }
      }
    }
    Label {
      Layout.fillWidth: true
      text: Omunculus.modelOf(node.agent)
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideMiddle
    }
    Label {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.minimumHeight: font.pixelSize + 4
      text: node.title
      color: node.idle ? Theme.dim : Theme.foreground
      font.pixelSize: 12
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      visible: !node.idle
      text: node.running ? "WORKING" + (Omunculus.calling[node.key] ? "  ·  " + Omunculus.calling[node.key] : "") : node.workState.toUpperCase()
      color: node.running ? node.agentTone : node.toYou > 0 ? Theme.warning : Theme.dim
      font.pixelSize: 11
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      visible: node.stage !== ""
      text: (node.passed ? "✓ " : "") + String(node.stageIndex + 1).padStart(2, "0") + " · " + node.stage.toUpperCase()
      color: node.passed ? Theme.success : node.idle ? Theme.secondary : node.agentTone
      font.pixelSize: 11
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: !node.idle
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: { node.forceActiveFocus(); node.chosen() }
  }
  FocusRing {}
}
