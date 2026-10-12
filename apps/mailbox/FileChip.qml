import QtQuick
import "kit/ui"

// FileChip is one file of a message: its name and size. Attached, clicking
// it saves it to the downloads directory and opens it; about to be sent,
// it has a way to take it off.
Rectangle {
  id: chip

  property string name
  property string detail
  // Whether it is about to be sent, and can be taken off.
  property bool pending: false

  signal chosen()
  signal removed()

  implicitWidth: row.implicitWidth + 16
  implicitHeight: 26
  color: pointer.containsMouse && !pending ? Qt.alpha(Theme.primary, 0.08) : Qt.alpha(Theme.foreground, 0.03)
  border.color: pointer.containsMouse && !pending ? Theme.primary : Theme.line

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 8
    Icon { anchors.verticalCenter: parent.verticalCenter; name: chip.pending ? "plus" : "import"; size: 11; color: Theme.primary }
    Label { anchors.verticalCenter: parent.verticalCenter; text: chip.name; font.pixelSize: 12; elide: Text.ElideMiddle; width: Math.min(implicitWidth, 260) }
    Label { anchors.verticalCenter: parent.verticalCenter; text: chip.detail; color: Theme.dim; font.pixelSize: 10; visible: text !== "" }
    Icon {
      visible: chip.pending
      anchors.verticalCenter: parent.verticalCenter
      name: "close"
      size: 10
      color: remove.containsMouse ? Theme.error : Theme.dim
      MouseArea { id: remove; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.removed() }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    enabled: !chip.pending
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.chosen()
  }
  Hint { visible: pointer.containsMouse && !chip.pending; text: "save to downloads and open" }
}
