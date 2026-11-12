import QtQuick
import "kit/ui"

// FolderTab is one folder, in one of three forms. "full": its icon, its name
// and its count in a box, outlined in the accent while current. "rail": the
// count alone, for a folded rail. "pill": its name and count in a rounded
// pill, for a phone. `attention` colours the count in the accent while it is
// above zero: mail or reviews that want you.
Item {
  id: tab

  property string name
  property string icon
  property string label
  property int count: 0
  property bool attention: false
  property string form: "full"
  readonly property bool current: Mail.folder === name
  readonly property bool hovered: pointer.containsMouse
  readonly property color ink: attention && count > 0 ? Theme.primary : Theme.dim

  implicitHeight: form === "pill" ? 30 : form === "rail" ? 34 : 30
  implicitWidth: form === "pill" ? pill.implicitWidth + 24 : form === "rail" ? 34 : 160

  Rectangle {
    anchors.fill: parent
    color: tab.current ? Theme.highlight : tab.hovered ? Qt.alpha(Theme.primary, 0.05) : Qt.alpha(Theme.foreground, tab.form === "full" ? 0.03 : 0)
    border.color: tab.current ? Theme.primary : tab.form === "pill" ? Theme.line : "transparent"
    radius: tab.form === "pill" ? height / 2 : 0
    Behavior on color { ColorAnimation { duration: 150 } }
  }

  Row {
    visible: tab.form === "full"
    anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
    spacing: 10
    Icon { anchors.verticalCenter: parent.verticalCenter; name: tab.icon; size: 14; color: tab.current ? Theme.foreground : Theme.dim }
    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: tab.label.toUpperCase()
      color: tab.current ? Theme.foreground : tab.hovered ? Theme.foreground : Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 2
    }
  }
  Rectangle {
    visible: tab.form === "full"
    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
    width: 22
    height: 18
    color: "transparent"
    border.color: tab.ink
    Label { anchors.centerIn: parent; text: tab.count; color: tab.ink; font.pixelSize: 10 }
  }

  Label {
    visible: tab.form === "rail"
    anchors.centerIn: parent
    text: tab.count
    color: tab.current ? Theme.foreground : tab.ink
    font.pixelSize: 11
    font.bold: tab.current
  }

  Label {
    id: pill
    visible: tab.form === "pill"
    anchors.centerIn: parent
    text: tab.label.toUpperCase() + (tab.count > 0 && tab.attention ? " " + tab.count : "")
    color: tab.current ? Theme.foreground : tab.ink
    font.pixelSize: 10
    font.letterSpacing: 1
  }

  Hint { active: pointer.containsMouse && tab.form === "rail"; text: tab.label + ", " + tab.count }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: Mail.folder = tab.name
  }
}
