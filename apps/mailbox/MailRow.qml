import QtQuick
import QtQuick.Layouts

// MailRow is one mail in a list: its state, when it last moved, its subject,
// and a line of what came back. Unread, it is bold behind an accent bar.
Rectangle {
  id: row

  required property var modelData
  readonly property var mail: modelData
  readonly property bool current: Mail.selected === mail.id
  readonly property bool unread: Mail.isUnread(mail)

  implicitHeight: content.implicitHeight + 24
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.03) : "transparent"
  Behavior on color { ColorAnimation { duration: 120 } }

  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: row.mail.state === "decide" ? Theme.warning : Theme.primary
    visible: row.unread || row.current
    opacity: row.unread ? 1 : 0.5
  }

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 16; rightMargin: 14 }
    spacing: 5

    RowLayout {
      Layout.fillWidth: true
      StateMark { state: row.mail.state }
      Item { Layout.fillWidth: true }
      Label { text: Mail.when(row.mail.at); color: Theme.dim; font.pixelSize: 10 }
    }
    Label {
      Layout.fillWidth: true
      text: row.mail.subject
      font.bold: row.unread
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      text: row.mail.snippet
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
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
    onClicked: Mail.open(row.mail.id)
  }
}
