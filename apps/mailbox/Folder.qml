import QtQuick
import QtQuick.Layouts
import "gui"

// Folder is one entry of the sidebar: its icon, its name and how many mails
// in it want you.
Rectangle {
  id: folder

  property string name
  property string icon
  property string label
  property int count: 0
  property color tone: Theme.primary
  readonly property bool current: Mail.folder === name && !Mail.composing

  implicitHeight: 34
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.03) : "transparent"

  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: Theme.primary
    visible: folder.current
  }

  RowLayout {
    anchors { fill: parent; leftMargin: 14; rightMargin: 12 }
    spacing: 10
    Icon { name: folder.icon; size: 13; color: folder.current ? Theme.primary : Theme.dim }
    Label { Layout.fillWidth: true; text: folder.label; font.letterSpacing: 1 }
    Label {
      visible: folder.count > 0
      text: folder.count
      color: folder.tone
      font.pixelSize: 11
      font.bold: true
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { Mail.folder = folder.name; Mail.composing = false }
  }
}
