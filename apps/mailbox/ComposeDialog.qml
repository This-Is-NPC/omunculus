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

  // Whether the agents matching To are listed, and the one Enter takes.
  property bool listing: false
  property int current: 0

  readonly property var suggestions: Mailbox.suggest(Mail.recipients, address.text)
    .filter(item => dialog.to === null || item.address !== dialog.to.address).slice(0, 8)

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
    listing = false
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
    listing = false
    body.forceActiveFocus()
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
        // The recipient: a click selects it, only its x (or Backspace, once
        // selected) removes it.
        Rectangle {
          id: chip
          visible: dialog.to !== null
          height: Theme.size.chip
          width: chipRow.implicitWidth + 16
          activeFocusOnTab: true
          color: activeFocus ? Qt.alpha(Theme.primary, 0.12) : "transparent"
          border.color: activeFocus ? Theme.primary : Theme.line
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
              dialog.to = null
              address.forceActiveFocus()
              event.accepted = true
            }
          }
          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 8
            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: dialog.to ? dialog.to.text : ""
              color: chip.activeFocus ? Theme.primary : Theme.foreground
              font.pixelSize: 11
              MouseArea { anchors.fill: parent; onClicked: chip.forceActiveFocus() }
            }
            IconButton {
              anchors.verticalCenter: parent.verticalCenter
              name: "close"
              size: 10
              tip: "remove " + (dialog.to ? dialog.to.name : "")
              onClicked: { dialog.to = null; address.forceActiveFocus() }
            }
          }
        }
        TextBox {
          id: address
          width: dialog.to === null ? 360 : 220
          placeholderText: Mail.projects.length === 0 ? (Mail.connected ? "reading the agents" : "the server does not answer") : dialog.to === null ? "an agent's name or address" : "another recipient"
          onTextEdited: { dialog.listing = true; dialog.current = 0 }
          onActiveFocusChanged: if (activeFocus) dialog.listing = true
          onAccepted: if (dialog.listing && dialog.suggestions.length > 0) dialog.pick(dialog.suggestions[dialog.current])
          Keys.onEscapePressed: event => {
            event.accepted = dialog.listing
            dialog.listing = false
          }
          Keys.onDownPressed: dialog.current = Math.min(dialog.suggestions.length - 1, dialog.current + 1)
          Keys.onUpPressed: dialog.current = Math.max(0, dialog.current - 1)
        }
      }
      // The agents whose name or address holds what is typed, under the field.
      Rectangle {
        Layout.fillWidth: true
        visible: dialog.listing && address.activeFocus
        implicitHeight: matches.implicitHeight + 2
        color: Theme.background
        border.color: Theme.line
        Column {
          id: matches
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
          Repeater {
            model: dialog.suggestions
            delegate: Rectangle {
              id: line
              required property var modelData
              required property int index
              width: matches.width
              height: 28
              color: index === dialog.current || hover.containsMouse ? Qt.alpha(Theme.primary, 0.1) : "transparent"
              Label {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                text: line.modelData.text
                font.pixelSize: 12
                elide: Text.ElideRight
              }
              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: dialog.pick(line.modelData)
              }
            }
          }
          Label {
            visible: dialog.suggestions.length === 0
            leftPadding: 12
            height: 28
            verticalAlignment: Text.AlignVCenter
            text: Mail.projects.length === 0 ? "reading the agents" : "no agent matches"
            color: Theme.dim
            font.pixelSize: 12
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
