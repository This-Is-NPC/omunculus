pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import "Breakpoints.js" as Breakpoints

// FilePicker holds the files a message will carry, a neutral chip for each
// picked as tall as the Attach button beside it: a file icon, its name and a
// small remove icon, which takes it off; `pick()` asks for more. Empty, it
// takes no room.
Flow {
  id: picker

  // The paths picked, in order.
  property var paths: []

  // The paths picked; the picker is emptied.
  function take() {
    const picked = paths
    paths = []
    return picked
  }

  // Asks for files to add.
  function pick() { dialog.open() }

  visible: paths.length > 0
  spacing: Theme.space.tight

  Repeater {
    model: picker.paths
    delegate: Rectangle {
      id: chip
      required property string modelData
      required property int index
      implicitHeight: Breakpoints.target(Window.width)
      implicitWidth: content.implicitWidth + 2 * Theme.space.gap
      width: Math.min(implicitWidth, picker.width)
      color: Qt.alpha(Theme.foreground, 0.04)
      border.color: Theme.line
      Row {
        id: content
        anchors { left: parent.left; leftMargin: Theme.space.gap; verticalCenter: parent.verticalCenter }
        spacing: Theme.space.gap
        Icon { anchors.verticalCenter: parent.verticalCenter; name: "file"; size: 12; color: Theme.dim }
        Label {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, Math.max(0, picker.width - 3 * Theme.space.gap - 2 * 12 - 2 * content.spacing))
          text: chip.modelData.split("/").pop()
          color: Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideMiddle
        }
        Icon {
          id: remove
          anchors.verticalCenter: parent.verticalCenter
          name: "close"
          size: 10
          color: take.containsMouse ? Theme.error : Theme.dim
          MouseArea {
            id: take
            anchors { fill: parent; margins: -Theme.space.gap }
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: picker.paths = picker.paths.filter((path, at) => at !== chip.index)
          }
        }
      }
      Hint { active: take.containsMouse; text: "take " + chip.modelData.split("/").pop() + " off" }
    }
  }

  FileDialog {
    id: dialog
    title: "Attach files"
    fileMode: FileDialog.OpenFiles
    onAccepted: {
      const picked = selectedFiles.map(url => decodeURIComponent(String(url).replace(/^file:\/\//, "")))
      picker.paths = picker.paths.concat(picked.filter(path => !picker.paths.includes(path)))
    }
  }
}
