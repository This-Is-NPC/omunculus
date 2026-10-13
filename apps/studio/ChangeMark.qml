import QtQuick
import "kit/ui"

// ChangeMark names, in violet, the workspace that changes what it stands beside:
// a depth's workflow, an agent's model, the tables a workspace overlays.
Rectangle {
  property alias text: mark.text

  implicitWidth: mark.implicitWidth + 8
  implicitHeight: 15
  color: "transparent"
  border.color: Qt.alpha(Theme.magenta, 0.6)
  Label { id: mark; anchors.centerIn: parent; color: Theme.magenta; font.pixelSize: 9 }
}
