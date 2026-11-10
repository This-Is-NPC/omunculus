pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ComposeDialog writes a new message: To holds one agent as a chip, found by
// typing its name or address (a thread is with one agent, so a second is
// refused, saying so), then Subject, the message and the files it carries.
// It starts with the project's default agent in To when its config declares
// one. Closing it with something written keeps it in Drafts; DISCARD drops it.
ModalDialog {
  id: dialog

  // The recipient, as Mailbox.person makes it, or null.
  property var to: null
  property string subject: ""
  // The draft it was opened from, "" for a new message.
  property string draft: ""
  // Why the last recipient picked was not taken; "" while nothing is wrong.
  property string refusal: ""
  property bool discarding: false

  readonly property var suggestions: Mailbox.suggest(Mailbox.recipients(Mail.projects), address.text)
    .filter(item => dialog.to === null || item.address !== dialog.to.address).slice(0, 6)

  maxWidth: 640

  // Opens it for `preset`: {draft}, or {subject, body} for a message started
  // from another.
  function start(preset) {
    const saved = preset.draft || null
    draft = saved ? saved.id : ""
    to = saved ? (saved.agent !== "" ? Mailbox.person(saved.agent, saved.project) : null) : Mail.defaultRecipient()
    subject = saved ? saved.subject : preset.subject || ""
    body.text = saved ? saved.body : preset.body || ""
    address.text = ""
    refusal = ""
    discarding = false
    open()
  }

  // Takes `item` as the recipient, unless one is already there.
  function pick(item) {
    if (to !== null && to.address !== item.address) {
      refusal = "A message goes to one agent. Remove " + to.name + " to write to " + item.name + "."
      return
    }
    to = item
    refusal = ""
    address.text = ""
  }

  onOpened: { panel.dialogOpen = true; (to === null ? address : body).forceActiveFocus() }
  onClosed: {
    panel.dialogOpen = false
    const written = subject.trim() !== "" || body.text.trim() !== ""
    if (discarding || !written) {
      if (draft !== "")
        Mail.discardDraft(draft)
    } else {
      Mail.saveDraft({ id: draft, project: to ? to.project : "", agent: to ? to.agent : "", subject: subject, body: body.text })
    }
    body.text = ""
    to = null
  }

  function send() {
    if (to === null || (subject.trim() === "" && body.text.trim() === ""))
      return
    Mail.send(to.project, to.agent, subject, body.take(), files.take(), draft)
    discarding = true
    close()
  }

  contentItem: DialogPanel {
    id: panel
    index: "01"
    title: "NEW MESSAGE"

    ColumnLayout {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: 12

      Caption { text: "TO" }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        Chip {
          visible: dialog.to !== null
          checked: true
          icon: "close"
          text: dialog.to ? dialog.to.text : ""
          tip: "remove " + (dialog.to ? dialog.to.name : "")
          onClicked: dialog.to = null
        }
        TextBox {
          id: address
          visible: dialog.to === null
          width: 280
          placeholderText: Mail.projects.length === 0 ? (Mail.connected ? "reading the agents" : "the server does not answer") : "an agent's name or address"
          onAccepted: if (dialog.suggestions.length > 0) dialog.pick(dialog.suggestions[0])
        }
      }
      Flow {
        Layout.fillWidth: true
        visible: address.activeFocus || address.text !== ""
        spacing: 6
        Repeater {
          model: dialog.suggestions
          delegate: Chip {
            required property var modelData
            text: modelData.text
            onClicked: dialog.pick(modelData)
          }
        }
      }
      FieldError { Layout.fillWidth: true; text: dialog.refusal }

      Caption { text: "SUBJECT" }
      TextBox {
        Layout.fillWidth: true
        text: dialog.subject
        onTextChanged: dialog.subject = text
        placeholderText: "what it is about"
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
        IconButton {
          name: "attach"
          tip: "files to send with the message"
          onClicked: files.pick()
        }
        FilePicker { id: files; Layout.fillWidth: true }
        cancelText: "DISCARD"
        primaryText: "SEND"
        primaryIcon: "enter"
        primaryEnabled: dialog.to !== null && (dialog.subject.trim() !== "" || body.text.trim() !== "") && Mail.connected
        onCancelled: { dialog.discarding = true; dialog.close() }
        onAccepted: dialog.send()
      }
    }
  }
}
