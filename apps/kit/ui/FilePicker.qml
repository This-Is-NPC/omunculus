pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs

// FilePicker holds the files a message will carry, a chip for each picked,
// which takes it off when chosen; `pick()` asks for more. Empty, it takes
// no room.
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
