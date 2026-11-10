import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ThreadRow is one thread in the list, as a mail client's row: a hairline
// outline at rest, a wash under the pointer and the accent outline when it is
// the thread on screen. Unread, it is bold with a dot. It shows who wrote,
// the subject with the start of the last message, its label and its time.
Rectangle {
  id: row

  property var thread
  readonly property bool current: Mail.selected === thread.key
  readonly property bool unread: Mail.isUnread(thread)

  signal chosen()

  // A narrow row gives its label and project a line of their own, so the
  // sender and the subject keep the width.
  readonly property bool narrow: width < 380

  implicitHeight: lines.implicitHeight + 16
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : unread ? Qt.alpha(Theme.foreground, 0.05) : "transparent"
  border.color: current ? Theme.primary : Theme.line
  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on border.color { ColorAnimation { duration: 120 } }


  ColumnLayout {
    id: lines
    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 14; topMargin: 8 }
    spacing: 3

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Dot { size: 8; tone: Theme.primary; opacity: row.unread ? 1 : 0 }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.thread.parties
        color: row.unread ? Theme.foreground : Theme.dim
        font.pixelSize: 12
        font.bold: row.unread
        elide: Text.ElideRight
      }
      MailLabel { visible: !row.narrow && kind !== ""; kind: row.thread.label }
      ProjectTag { visible: !row.narrow; name: row.thread.project }
      Label { text: Mail.when(row.thread.at); color: row.unread ? Theme.primary : Theme.dim; font.pixelSize: 10 }
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.fillWidth: row.narrow
        Layout.minimumWidth: 0
        Layout.maximumWidth: row.narrow ? -1 : row.width * 0.55
        text: row.thread.subject
        color: row.unread ? Theme.foreground : Theme.dim
        font.pixelSize: 13
        font.bold: row.unread
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        visible: !row.narrow
        text: row.thread.snippet
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
    RowLayout {
      Layout.fillWidth: true
      visible: row.narrow
      spacing: 8
      MailLabel { visible: kind !== ""; kind: row.thread.label }
      ProjectTag { name: row.thread.project }
    }
    Item { implicitHeight: 5 }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.chosen()
  }
}
