import QtQuick
import "kit/ui"

// FolderTab is one folder: its name, dim until hovered,
// in the accent with an underline while current, and how many threads in it
// want you, behind a dot when any does. Choosing it nudges it. Folded to a
// rail, only its icon shows, the count on a badge, and with `named` the
// current one also keeps its name beside its icon.
Item {
  id: tab

  property string name
  property string icon
  property string label
  property int count: 0
  property color tone: Theme.primary
  property bool rail: false
  property bool named: false
  readonly property bool current: Mail.folder === name
  readonly property bool hovered: pointer.containsMouse

  implicitHeight: rail ? 44 : 34
  readonly property bool showName: rail && named && current
  implicitWidth: rail ? (showName ? 44 + 6 + railName.implicitWidth + 10 : 44) : row.implicitWidth + 28

  Row {
    id: row
    visible: !tab.rail
    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
    spacing: 10
    transform: Translate { id: nudge }
    Dot { anchors.verticalCenter: parent.verticalCenter; tone: tab.tone; opacity: tab.count > 0 ? 1 : 0 }
    Label {
      id: caption
      anchors.verticalCenter: parent.verticalCenter
      text: tab.label.toUpperCase()
      color: tab.current ? Theme.primary : tab.hovered ? Theme.foreground : Theme.dim
      font.pixelSize: 11
      font.letterSpacing: 2
      Behavior on color { ColorAnimation { duration: 150 } }
      Rectangle {
        anchors { left: parent.left; top: parent.bottom; topMargin: 3 }
        height: 1
        width: tab.current ? parent.width : 0
        color: Theme.primary
        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      visible: tab.count > 0
      text: tab.count
      color: tab.tone
      font.pixelSize: 11
    }
  }

  IconButton {
    visible: tab.rail
    anchors { left: tab.showName ? parent.left : undefined; leftMargin: 6; verticalCenter: parent.verticalCenter; horizontalCenter: tab.showName ? undefined : parent.horizontalCenter }
    name: tab.icon
    tip: tab.label
    tone: tab.tone
    highlighted: tab.current
    count: tab.count
    onClicked: tab.choose()
  }

  Label {
    id: railName
    visible: tab.showName
    anchors { left: parent.left; leftMargin: 44 + 6; verticalCenter: parent.verticalCenter }
    text: tab.label.toUpperCase()
    color: Theme.primary
    font.pixelSize: 11
    font.letterSpacing: 2
  }

  function choose() {
    Mail.folder = tab.name
    nudging.restart()
  }

  SequentialAnimation {
    id: nudging
    NumberAnimation { target: nudge; property: "x"; to: 14; duration: 180; easing.type: Easing.OutCubic }
    NumberAnimation { target: nudge; property: "x"; to: 0; duration: 240; easing.type: Easing.OutCubic }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: !tab.rail
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: tab.choose()
  }
}
