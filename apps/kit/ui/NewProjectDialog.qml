import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts

// NewProjectDialog registers a project with the running server through
// `client`, a Project: its id and the path of its config file, typed or
// picked. The server writes it into its registry; `registered` follows.
ModalDialog {
  id: dialog

  property var client: null
  property bool sending: false

  signal registered(string id)

  maxWidth: 460
  enter: null
  exit: null
  onOpened: {
    name.text = ""
    config.text = ""
    failure.message = ""
    sending = false
    name.forceActiveFocus()
  }

  function submit() {
    if (sending || name.text === "" || config.text === "")
      return
    const id = name.text
    sending = true
    failure.message = ""
    client.registerProject(id, config.text, () => {
      sending = false
      dialog.close()
      dialog.registered(id)
    }, reason => {
      sending = false
      failure.message = reason
    })
  }

  contentItem: DialogPanel {
    dialogOpen: dialog.visible
    implicitHeight: form.implicitHeight + 56
    index: "+"
    title: "new project"
    active: true

    ColumnLayout {
      id: form
      anchors.fill: parent
      spacing: 10

      Caption { text: "ID" }
      TextBox {
        id: name
        Layout.fillWidth: true
        dense: true
        onAccepted: config.forceActiveFocus()
      }

      Caption { Layout.topMargin: 8; text: "CONFIG" }
      RowLayout {
        Layout.fillWidth: true
        spacing: 8
        TextBox {
          id: config
          Layout.fillWidth: true
          dense: true
          placeholderText: "/path/to/omunculus.toml"
          onAccepted: dialog.submit()
        }
        Chip {
          text: "PICK FILE"
          tip: "choose the project's omunculus.toml"
          onClicked: picker.open()
        }
      }

      StatusMessage {
        id: failure
        Layout.fillWidth: true
        Layout.topMargin: 8
        visible: message !== ""
        kind: "error"
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8
        spacing: 8
        Item { Layout.fillWidth: true }
        Chip { text: "CANCEL"; onClicked: dialog.close() }
        TraceButton {
          role: "primary"
          dense: true
          icon: "plus"
          text: "REGISTER"
          busy: dialog.sending
          enabled: name.text !== "" && config.text !== "" && !dialog.sending
          onClicked: dialog.submit()
        }
      }
    }
  }

  FileDialog {
    id: picker
    title: "The project's config"
    nameFilters: ["TOML files (*.toml)"]
    onAccepted: config.text = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""))
  }
}
