pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// ComposeDialog writes a new thread, as eco's dialogs do: To is required, one
// agent of depth 0 of one project, which the thread keeps; then what you
// need and the files it needs. Esc or CANCEL leaves it as it was written.
ModalDialog {
  id: dialog

  property string project: ""
  property string agent: ""
  // Every agent a thread can be with, as {project, agent}.
  readonly property var recipients: Mail.projects.reduce((all, place) => all.concat(place.agents.map(name => ({ project: place.id, agent: name }))), [])

  maxWidth: 640

  // With one agent to write to, it is the one.
  onAboutToShow: if (recipients.length === 1 && agent === "") { project = recipients[0].project; agent = recipients[0].agent }
  onOpened: { panel.dialogOpen = true; body.focusEntry() }
  onClosed: panel.dialogOpen = false

  function send() {
    if (agent === "" || body.text.trim() === "")
      return
    Mail.send(project, agent, body.take(), files.take())
    close()
  }

  contentItem: DialogPanel {
    id: panel
    index: "01"
    title: "NEW THREAD"

    ColumnLayout {
      id: content
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: 14

      Caption { text: "TO" }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
          model: dialog.recipients
          delegate: Chip {
            required property var modelData
            checked: dialog.project === modelData.project && dialog.agent === modelData.agent
            text: modelData.agent.toUpperCase() + "  ·  " + modelData.project.toUpperCase()
            onClicked: { dialog.project = modelData.project; dialog.agent = modelData.agent }
          }
        }
        Label {
          visible: dialog.recipients.length === 0
          text: Mail.connected ? "READING THE AGENTS" : "THE SERVER DOES NOT ANSWER"
          color: Theme.dim
          font.pixelSize: 10
          font.letterSpacing: 2
        }
      }
      Label {
        Layout.fillWidth: true
        text: dialog.agent === "" ? "Choose who it is for. The thread stays with that agent."
          : dialog.agent + " in " + dialog.project + " gets it; you hear back in the thread."
        color: dialog.agent === "" ? Theme.warning : Theme.dim
        font.pixelSize: 11
        wrapMode: Text.Wrap
      }

      Caption { text: "MESSAGE" }
      Editor {
        id: body
        Layout.fillWidth: true
        Layout.preferredHeight: 180
        placeholderText: "what you need"
        onSubmitted: dialog.send()
      }

      DialogFooter {
        FilePicker { id: files; Layout.fillWidth: true }
        primaryText: "SEND"
        primaryIcon: "enter"
        primaryEnabled: dialog.agent !== "" && body.text.trim() !== "" && Mail.connected
        primaryDim: dialog.agent === ""
        onCancelled: dialog.close()
        onAccepted: dialog.send()
      }
    }
  }
}
