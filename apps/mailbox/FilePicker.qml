pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import "gui"

// FilePicker holds the files a message will carry: a button that picks them
// and a chip for each, which can be taken off.
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

  spacing: 6

  TraceButton {
    dense: true
    role: "progress"
    icon: "plus"
    text: "ATTACH"
    tip: "files to send with the message"
    onClicked: dialog.open()
  }

  Repeater {
    model: picker.paths
    delegate: FileChip {
      required property string modelData
      required property int index
      name: modelData.split("/").pop()
      pending: true
      onRemoved: picker.paths = picker.paths.filter((path, at) => at !== index)
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
