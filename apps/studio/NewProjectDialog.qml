pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// NewProjectDialog registers a project with the running server: its id and
// the path of its config file. The server writes it into its registry.
ModalDialog {
  id: dialog

  signal registered(string id)

  maxWidth: 460
  enter: null
  exit: null
  onOpened: { name.value = ""; path.value = ""; failure.text = ""; name.input.forceActiveFocus() }

  function submit() {
    Studio.registerProject(name.value, path.value, () => {
      dialog.close()
      dialog.registered(name.value)
    }, reason => failure.text = reason)
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
      spacing: 18

      Field { id: name; Layout.fillWidth: true; label: "id"; onEdited: text => value = text }
      Field {
        id: path
        Layout.fillWidth: true
        label: "config"
        placeholder: "/path/to/the project config"
        onEdited: text => value = text
        onCommitted: dialog.submit()
      }
      FieldError { id: failure; Layout.fillWidth: true }
      RowLayout {
        Layout.fillWidth: true
        Item { Layout.fillWidth: true }
        Chip { text: "CANCEL"; onClicked: dialog.close() }
        TraceButton {
          dense: true
          icon: "plus"
          text: "REGISTER"
          enabled: name.value !== "" && path.value !== ""
          onClicked: dialog.submit()
        }
      }
    }
  }
}
