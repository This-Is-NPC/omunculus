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
    name.input.text = ""
    config.input.text = ""
    failure.text = ""
    sending = false
    name.input.forceActiveFocus()
  }

  function submit() {
    if (sending || name.input.text === "" || config.input.text === "")
      return
    const id = name.input.text
    sending = true
    failure.text = ""
    client.registerProject(id, config.input.text, () => {
      sending = false
      dialog.close()
      dialog.registered(id)
    }, reason => {
      sending = false
      failure.text = reason
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
      spacing: Theme.space.gap

      Field {
        id: name
        Layout.fillWidth: true
        label: "ID"
        Connections {
          target: name.input
          function onAccepted() { config.input.forceActiveFocus() }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Field {
          id: config
          Layout.fillWidth: true
          label: "CONFIG"
          placeholder: "/path/to/the project config"
          Connections {
            target: config.input
            function onAccepted() { dialog.submit() }
          }
        }
        Chip {
          Layout.alignment: Qt.AlignBottom
          text: "PICK FILE"
          tip: "choose the project config"
          onClicked: picker.open()
        }
      }

      // Why the server refused it.
      FieldError { id: failure; Layout.fillWidth: true }

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
          enabled: name.input.text !== "" && config.input.text !== "" && !dialog.sending
          onClicked: dialog.submit()
        }
      }
    }
  }

  FileDialog {
    id: picker
    title: "The project's config"
    nameFilters: ["TOML files (*.toml)"]
    onAccepted: config.input.text = decodeURIComponent(String(selectedFile).replace(/^file:\/\//, ""))
  }
}
