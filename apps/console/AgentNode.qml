import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// AgentNode is one agent on the agents map, at a fixed size: its ring in the
// agent's colour, which keeps leaving it while the agent runs, its name and
// model, and the work it is on. Its border is its state — running, waiting on
// you, broken, done — and a badge counts what it asked that still waits. An
// agent configured at that depth with nothing to do shows hollow.
Rectangle {
  id: node

  // The work, or "" for the root agent's own conversation.
  property string key: ""
  property string agent: ""
  property string title: ""
  // A configured agent with no work here.
  property bool idle: false
  property bool selected: false
  signal chosen()

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property string workState: work ? work.state : "open"
  readonly property bool running: !idle && Omunculus.busy(key)
  readonly property var asks: idle ? [] : Omunculus.asked(key)
  readonly property int toYou: asks.filter(request => request.arbiter === "human").length + (idle ? 0 : Omunculus.unreadFrom(key).length)
  readonly property color agentTone: Omunculus.toneOf(agent)
  readonly property color stateTone: toYou > 0 ? Theme.warning
    : workState === "broken" ? Theme.error
    : running ? agentTone
    : Theme.line

  width: 200
  height: 66
  color: selected ? Qt.alpha(Theme.primary, 0.1) : pointer.containsMouse ? Theme.highlight : Theme.background
  border.color: selected ? Theme.primary : stateTone
  border.width: selected || toYou > 0 || running ? 2 : 1
  opacity: idle ? 0.45 : workState === "done" || workState === "cancelled" ? 0.6 : 1
  Behavior on color { ColorAnimation { duration: 140 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }
  Behavior on opacity { NumberAnimation { duration: 200 } }

  ColumnLayout {
    anchors { fill: parent; margins: 10; leftMargin: 12; rightMargin: 12 }
    spacing: 6

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Item {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 12
        implicitHeight: 12
        Rectangle {
          anchors.centerIn: parent
          width: 8
          height: 8
          radius: 4
          color: node.running ? node.agentTone : "transparent"
          border.color: node.agentTone
        }
        // A ring that keeps leaving the dot while the agent runs.
        Rectangle {
          id: ring
          anchors.centerIn: parent
          width: 8
          height: 8
          radius: width / 2
          color: "transparent"
          border.color: node.agentTone
          visible: node.running
          ParallelAnimation {
            running: node.running
            loops: Animation.Infinite
            NumberAnimation { target: ring; property: "width"; from: 8; to: 24; duration: 1400; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "height"; from: 8; to: 24; duration: 1400; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: 1400 }
          }
        }
      }
      Label {
        Layout.alignment: Qt.AlignVCenter
        text: node.agent.toUpperCase()
        color: node.agentTone
        font.pixelSize: 10
        font.letterSpacing: 2.5
      }
      Label {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        text: Omunculus.modelOf(node.agent)
        color: Theme.dim
        font.pixelSize: 9
        elide: Text.ElideRight
      }
      // What it asked that still waits: lit when any of it waits on you.
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        visible: node.asks.length > 0 || node.toYou > 0
        implicitWidth: Math.max(implicitHeight, tally.implicitWidth + 8)
        implicitHeight: 15
        color: node.toYou > 0 ? Theme.warning : "transparent"
        border.color: node.toYou > 0 ? Theme.warning : Theme.dim
        Label {
          id: tally
          anchors.centerIn: parent
          text: Math.max(node.asks.length, node.toYou)
          color: node.toYou > 0 ? Theme.badgeForeground : Theme.dim
          font.pixelSize: 9
          font.bold: true
        }
      }
    }

    Label {
      Layout.fillWidth: true
      text: node.idle ? "idle" : node.title
      color: node.idle ? Theme.dim : Theme.foreground
      font.pixelSize: 11
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: !node.idle
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: node.chosen()
  }
}
