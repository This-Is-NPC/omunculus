import QtQuick

// StatusMessage tells what happened or what is going on: a box tinted by its
// kind, the kind's icon and name over the message, which wraps. Controls given
// to it sit on its right.
Rectangle {
  id: status

  default property alias actions: actionRow.data
  property string message
  property string kind: "success"
  readonly property color tone: kind === "error" ? Theme.error : kind === "info" ? Theme.primary : Theme.success

  implicitHeight: Math.max(68, toast.implicitHeight + 28)
  color: Qt.alpha(tone, 0.06)
  border.color: Qt.alpha(tone, 0.5)

  Column {
    id: toast
    anchors { left: parent.left; right: parent.right; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset + actionRow.room; verticalCenter: parent.verticalCenter }
    spacing: 7
    Row {
      spacing: Theme.space.tight
      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: status.kind === "error" ? "warning" : status.kind === "info" ? "info" : "check"
        size: 11
        color: status.tone
      }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        text: ({ error: "ERROR", info: "NOTICE", success: "DONE" })[status.kind]
        color: status.tone
        font.pixelSize: 9
        font.letterSpacing: 2
      }
    }
    Label {
      width: parent.width
      text: status.message
      color: Theme.foreground
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
  }

  Row {
    id: actionRow
    // The width the controls take from the message.
    readonly property real room: visibleChildren.length > 0 ? width + 10 : 0
    anchors { right: parent.right; rightMargin: Theme.space.cell; verticalCenter: parent.verticalCenter }
    spacing: 8
  }
}
