import QtQuick
import QtQuick.Layouts
import "kit/ui"

// MailFooter is the last row of a message being written: Attach and the files
// picked on the left, then DISCARD and SEND, the screen's one solid action,
// enabled once there is something to send.
RowLayout {
  id: footer

  // Whether the message can carry files, and whether it can be sent.
  property bool attachable: true
  property bool sendable: false
  // How many files are picked.
  readonly property int fileCount: files.paths.length
  // Takes the files picked, emptying the picker.
  function take() { return files.take() }

  signal discarded()
  signal sent()

  Layout.fillWidth: true
  spacing: 8

  IconButton {
    visible: footer.attachable
    name: "attach"
    tip: "files to send with the message"
    onClicked: files.pick()
  }
  FilePicker { id: files; Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter; visible: footer.attachable && paths.length > 0 }
  Item { Layout.fillWidth: true }
  TraceButton {
    dense: true
    role: "action"
    icon: "close"
    text: "DISCARD"
    onClicked: footer.discarded()
  }
  TraceButton {
    dense: true
    role: "primary"
    filled: true
    icon: "enter"
    text: "SEND"
    enabled: footer.sendable
    onClicked: footer.sent()
  }
}
