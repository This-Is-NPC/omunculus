import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ThreadRow is one thread in the list: its agent and project, when it last
// moved, its subject, and its last message. Unread, it is bold behind an
// accent bar.
Rectangle {
  id: row

  required property var modelData
  readonly property var thread: modelData
  readonly property bool current: Mail.selected === thread.key
  readonly property bool unread: Mail.isUnread(thread)

  signal chosen()

  implicitHeight: content.implicitHeight + 22
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.03) : "transparent"
  Behavior on color { ColorAnimation { duration: 120 } }

  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: row.thread.waiting.length > 0 ? Theme.warning : Theme.primary
    visible: row.unread || row.current || row.thread.waiting.length > 0
    opacity: row.unread || row.thread.waiting.length > 0 ? 1 : 0.5
  }

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 14 }
    spacing: 4

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.fillWidth: true
        text: row.thread.agent || "—"
        font.bold: row.unread
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      ProjectTag { name: row.thread.project }
      Label { text: Mail.when(row.thread.at); color: row.unread ? Theme.foreground : Theme.dim; font.pixelSize: 10 }
    }
    Label {
      Layout.fillWidth: true
      text: row.thread.subject
      font.bold: row.unread
      font.pixelSize: 13
      elide: Text.ElideRight
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      ThreadState { thread: row.thread }
      Label {
        Layout.fillWidth: true
        text: row.thread.snippet
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
  }

  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 1
    color: Theme.line
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { Mail.open(row.thread.key); row.chosen() }
  }
}
