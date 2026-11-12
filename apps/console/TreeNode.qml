import QtQuick
import QtQuick.Layouts
import "kit/ui"

// TreeNode is one agent of the chart: its name in its tone (AgentName) and,
// unless it is the person, its state as icon and word (StateMark). Working
// and waiting nodes are framed in their tone, the one picked in the accent
// and heavier; `chosen()` is its click.
SurfaceFrame {
  id: node

  property string agent: ""
  property color agentTone: Theme.dim
  property string state: ""
  property string stateText: ""
  property bool picked: false
  signal chosen()

  implicitHeight: content.implicitHeight + Theme.space.gap * 2
  active: picked || pointer.containsMouse
  border.width: picked ? 2 : 1
  border.color: picked ? Theme.primary : state === "needs-you" ? Theme.warning
    : state === "working" ? Qt.alpha(Theme.primary, 0.6) : pointer.containsMouse ? Theme.dim : Theme.line
  Accessible.role: Accessible.Button
  Accessible.name: agent + (state !== "" ? ", " + stateText.toLowerCase() : "")

  ColumnLayout {
    id: content
    x: Theme.space.gap
    y: Theme.space.gap
    width: parent.width - Theme.space.gap * 2
    spacing: Theme.space.line
    AgentName { name: node.agent; tone: node.agentTone; limit: content.width }
    StateMark { visible: node.state !== ""; Layout.fillWidth: true; state: node.state; text: node.stateText }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: node.chosen()
  }
}
