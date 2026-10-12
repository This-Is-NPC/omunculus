import QtQuick
import "gui"

// ProjectTag names the project a thread is in, as a small outlined tag.
Rectangle {
  id: tag
  property string name
  implicitWidth: label.implicitWidth + 12
  implicitHeight: 16
  color: "transparent"
  border.color: Theme.line
  Label {
    id: label
    anchors.centerIn: parent
    text: tag.name.toUpperCase()
    color: Theme.dim
    font.pixelSize: 9
    font.letterSpacing: 1.5
  }
}
