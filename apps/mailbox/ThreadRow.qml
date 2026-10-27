import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ThreadRow is one thread in the list, as a row of a table: a hairline
// outline at rest, a faint wash under the pointer, and the highlight with an
// accent outline when it is the thread on screen. A dot marks it unread; its
// subject decodes when it arrives while the list is on screen. Under it, its
// state, and what it is doing or else its last message.
Rectangle {
  id: row

  property var thread
  // Whether it arrived after the list was first filled.
  property bool fresh: false
  readonly property bool current: Mail.selected === thread.key
  readonly property bool unread: Mail.isUnread(thread)

  signal chosen()

  implicitHeight: 70
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
  border.color: current ? Theme.primary : Theme.line
  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on border.color { ColorAnimation { duration: 120 } }

  Component.onCompleted: if (fresh) subject.replay()

  ColumnLayout {
    anchors { fill: parent; leftMargin: 14; rightMargin: 14; topMargin: 10; bottomMargin: 10 }
    spacing: 4

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Dot { tone: Theme.primary; opacity: row.unread ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 140 } } }
      Label {
        Layout.fillWidth: true
        text: row.thread.agent || "—"
        color: row.unread ? Theme.foreground : Theme.dim
        font.pixelSize: 12
        font.bold: row.unread
        elide: Text.ElideRight
      }
      ProjectTag { name: row.thread.project }
      Label { text: Mail.when(row.thread.at); color: row.unread ? Theme.primary : Theme.dim; font.pixelSize: 10 }
    }
    DecodeLabel {
      id: subject
      Layout.fillWidth: true
      value: row.thread.subject
      soft: true
      revealOnStage: false
      font.pixelSize: 13
      font.bold: row.unread
      elide: Text.ElideRight
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      ThreadState { thread: row.thread }
      Label {
        Layout.fillWidth: true
        // What it is doing, while that says more than its last message.
        text: row.thread.status.brief || row.thread.snippet
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.chosen()
  }
}
