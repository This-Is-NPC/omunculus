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
  // Whether it arrived after the list was first filled.
  property bool fresh: false
  readonly property bool current: Mail.selected === thread.key
  readonly property bool unread: Mail.isUnread(thread)

  signal chosen()

  implicitHeight: 62
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
  border.color: current ? Theme.primary : Theme.line
  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on border.color { ColorAnimation { duration: 120 } }

  Component.onCompleted: if (fresh) subject.replay()

  ColumnLayout {
    anchors { fill: parent; leftMargin: 14; rightMargin: 14; topMargin: 8; bottomMargin: 8 }
    spacing: 3

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Dot { tone: Theme.primary; opacity: row.unread ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 140 } } }
      Label {
        Layout.fillWidth: true
        text: row.thread.parties
        color: row.unread ? Theme.foreground : Theme.dim
        font.pixelSize: 12
        font.bold: row.unread
        elide: Text.ElideRight
      }
      MailLabel { kind: row.thread.label }
      ProjectTag { name: row.thread.project }
      Label { text: Mail.when(row.thread.at); color: row.unread ? Theme.primary : Theme.dim; font.pixelSize: 10 }
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      DecodeLabel {
        id: subject
        Layout.maximumWidth: row.width * 0.55
        value: row.thread.subject
        soft: true
        revealOnStage: false
        font.pixelSize: 13
        font.bold: row.unread
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        text: row.thread.snippet
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
