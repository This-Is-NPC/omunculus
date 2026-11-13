import QtQuick
import QtQuick.Layouts
import "kit/ui"

// DuplicateJobDialog asks the name of the copy of a job, which the server makes
// as a draft: the same fields, to be resumed once it reads right. The server's
// refusal, as a name already taken, shows under the field.
ModalDialog {
  id: dialog

  // The job copied, by its name.
  property string source: ""
  property bool sending: false

  signal copied(string name)

  maxWidth: 460
  enter: null
  exit: null
  onOpened: {
    name.input.text = ""
    failure.text = ""
    sending = false
    name.input.forceActiveFocus()
  }

  function submit() {
    if (sending || name.input.text === "")
      return
    const copy = name.input.text
    sending = true
    failure.text = ""
    Omunculus.jobs.act(source, "duplicate", { as: copy }, () => {
      sending = false
      dialog.close()
      dialog.copied(copy)
    }, reason => {
      sending = false
      failure.text = reason
    })
  }

  contentItem: DialogPanel {
    dialogOpen: dialog.visible
    implicitHeight: form.implicitHeight + 56
    index: "+"
    title: "copy " + dialog.source
    active: true

    ColumnLayout {
      id: form
      anchors.fill: parent
      spacing: Theme.space.gap

      Field {
        id: name
        Layout.fillWidth: true
        label: "name of the copy"
        placeholder: dialog.source + "-copy"
        Connections {
          target: name.input
          function onAccepted() { dialog.submit() }
        }
      }
      FieldError { id: failure; Layout.fillWidth: true }
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Theme.space.gap
        spacing: Theme.space.gap
        Item { Layout.fillWidth: true }
        Chip { text: "CANCEL"; onClicked: dialog.close() }
        TraceButton {
          role: "primary"
          dense: true
          icon: "copy"
          text: "COPY"
          busy: dialog.sending
          enabled: name.input.text !== "" && !dialog.sending
          onClicked: dialog.submit()
        }
      }
    }
  }
}
