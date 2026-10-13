import QtQuick
import QtQuick.Layouts
import "kit/ui"

// StatusPanel is the open thread's state, under its subject, outlined and
// washed in the state's tone: what it is doing in plain words — who works on
// what and the tool it calls, what failed and why, where it stalled — what
// happens next, and the action that is yours to take: DECIDE while it waits
// on you, WRITE AGAIN when it failed or stalled.
Rectangle {
  id: panel

  required property var thread
  readonly property var status: thread.status
  readonly property string action: status.state === "waiting" ? "DECIDE"
    : status.state === "failed" || status.state === "stalled" ? "WRITE AGAIN" : ""

  signal decide()
  signal writeAgain()

  visible: status.label !== ""
  implicitHeight: content.implicitHeight + 20
  color: Qt.alpha(badge.tone, 0.06)
  border.color: Qt.alpha(badge.tone, 0.5)
  Behavior on color { ColorAnimation { duration: 200 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }

  RowLayout {
    id: content
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 10 }
    spacing: 12

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 5
      ThreadState { id: badge; thread: panel.thread }
      Label {
        Layout.fillWidth: true
        visible: text !== ""
        text: panel.status.line
        wrapMode: Text.Wrap
        maximumLineCount: 4
        elide: Text.ElideRight
        font.pixelSize: 12
      }
      Label {
        Layout.fillWidth: true
        visible: text !== ""
        text: panel.status.next
        color: Theme.dim
        wrapMode: Text.Wrap
        font.pixelSize: 11
      }
    }

    TraceButton {
      Layout.alignment: Qt.AlignVCenter
      visible: panel.action !== ""
      dense: true
      // Outlined: the bar's main action stays the one solid.
      role: "primary"
      tone: badge.tone
      icon: panel.status.state === "waiting" ? "warning" : "enter"
      text: panel.action
      tip: panel.status.state === "waiting" ? "what the thread waits on you for" : "write to " + panel.thread.agent + " again  ctrl+r"
      onClicked: panel.status.state === "waiting" ? panel.decide() : panel.writeAgain()
    }
  }
}
