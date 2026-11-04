pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs

// FilePicker holds the files a message will carry: a chip that picks them
// and a chip for each picked, which takes it off when chosen.
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

  spacing: Theme.space.tight

  Chip {
    icon: "plus"
    text: "ATTACH"
    tip: "files to send with the message"
    onClicked: dialog.open()
  }

  Repeater {
    model: picker.paths
    delegate: Chip {
      required property string modelData
      required property int index
      checked: true
      icon: "close"
      text: modelData.split("/").pop()
      tip: "take it off"
      onClicked: picker.paths = picker.paths.filter((path, at) => at !== index)
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
