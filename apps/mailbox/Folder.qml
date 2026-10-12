import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Folder is one entry of the folders: its icon, its name and how many threads
// in it want you. As a rail, only the icon, with the count on a badge.
Rectangle {
  id: folder

  property string name
  property string icon
  property string label
  property int count: 0
  property color tone: Theme.primary
  property bool rail: false
  readonly property bool current: Mail.folder === name && !Mail.composing

  signal chosen()

  implicitHeight: 36
  implicitWidth: rail ? 44 : 200
  color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.03) : "transparent"

  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: Theme.primary
    visible: folder.current
  }

  RowLayout {
    visible: !folder.rail
    anchors { fill: parent; leftMargin: 14; rightMargin: 12 }
    spacing: 10
    Icon { name: folder.icon; size: 13; color: folder.current ? Theme.primary : Theme.dim }
    Label { Layout.fillWidth: true; text: folder.label; elide: Text.ElideRight }
    Label { visible: folder.count > 0; text: folder.count; color: folder.tone; font.pixelSize: 11; font.bold: true }
  }

  Icon {
    visible: folder.rail
    anchors.centerIn: parent
    name: folder.icon
    size: 14
    color: folder.current ? Theme.primary : Theme.dim
  }
  Rectangle {
    visible: folder.rail && folder.count > 0
    anchors { right: parent.right; top: parent.top; margins: 3 }
    width: Math.max(height, tally.implicitWidth + 6)
    height: 13
    color: folder.tone
    Label { id: tally; anchors.centerIn: parent; text: folder.count; color: Theme.badgeForeground; font.pixelSize: 9; font.bold: true }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { Mail.folder = folder.name; Mail.composing = false; folder.chosen() }
  }
  Hint { visible: folder.rail && pointer.containsMouse; text: folder.label }
}
