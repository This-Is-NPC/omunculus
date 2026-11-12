import QtQuick
import QtQuick.Layouts
import "kit/ui"

// TreeNode is one agent of the chart: its name in its tone (AgentName) and,
// unless it is the person, its state as icon and word (StateMark). Working
// and waiting nodes are framed in their tone, the one picked in the accent
// and heavier; `chosen()` is its click. `wanted` is the width that shows its
// name and state whole.
SurfaceFrame {
  id: node

  property string agent: ""
  property color agentTone: Theme.dim
  property string state: ""
  property string stateText: ""
  property bool picked: false
  signal chosen()

  readonly property real wanted: Math.max(Theme.space.tight * 2 + nameWidth.advanceWidth, 12 + Theme.space.line + stateWidth.advanceWidth) + Theme.space.gap * 2 + 2

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

  TextMetrics { id: nameWidth; font.family: Theme.fontFamily; font.pixelSize: Theme.type.log.size; font.letterSpacing: Theme.type.header.tracking; text: node.agent }
  TextMetrics { id: stateWidth; font.family: Theme.fontFamily; font.pixelSize: 11; text: node.stateText }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: node.chosen()
  }
}
