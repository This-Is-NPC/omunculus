pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ComposeDialog writes a new message as a mail client does: a header of one
// line each, To and Subject, then the message. To holds one agent as a chip
// with its name (its address in the tip), found by typing a name or an
// address; a thread is with one agent, so a second is refused, saying so.
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
  // The width of the header's labels, so the fields line up.
  readonly property int labelWidth: 64

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

  readonly property bool sendable: to !== null && (subject.trim() !== "" || body.text.trim() !== "") && Mail.connected

  function send() {
    if (!sendable)
      return
    Mail.send(to.project, to.agent, subject, body.take(), foot.take(), draft)
    discarding = true
    close()
  }

  contentItem: DialogPanel {
    id: panel
    index: "01"
    title: "NEW MESSAGE"

    ColumnLayout {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: 8

      // To: the label, then the recipient and the field for another.
      RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Label { Layout.preferredWidth: dialog.labelWidth; text: "To"; color: Theme.dim; font.pixelSize: 12 }
        // The recipient as a pill: a click selects it, only its x (or
        // Backspace, once selected) removes it; its address is the tip.
        Rectangle {
          id: chip
          visible: dialog.to !== null
          implicitHeight: Theme.size.chip
          implicitWidth: chipRow.implicitWidth + 16
          activeFocusOnTab: true
          color: activeFocus ? Qt.alpha(Theme.primary, 0.12) : Qt.alpha(Theme.foreground, 0.04)
          border.color: activeFocus ? Theme.primary : Theme.line
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
              dialog.to = null
              address.forceActiveFocus()
              event.accepted = true
            }
          }
          MouseArea { id: pill; anchors.fill: parent; hoverEnabled: true; onClicked: chip.forceActiveFocus() }
          Hint { active: pill.containsMouse && dialog.to !== null; text: dialog.to ? dialog.to.address : "" }
          Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 8
            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: dialog.to ? dialog.to.name : ""
              color: chip.activeFocus ? Theme.primary : Theme.foreground
              font.pixelSize: 12
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
          Layout.fillWidth: true
          dense: true
          placeholderText: Mail.projects.length === 0 ? (Mail.connected ? "reading the agents" : "the server does not answer") : dialog.to === null ? "name or address" : "another recipient"
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
        Layout.leftMargin: dialog.labelWidth + 8
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
            color: Theme.foreground
            font.pixelSize: 12
          }
        }
      }
      FieldError { Layout.fillWidth: true; Layout.leftMargin: dialog.labelWidth + 8; text: dialog.refusal }

      RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Label { Layout.preferredWidth: dialog.labelWidth; text: "Subject"; color: Theme.dim; font.pixelSize: 12 }
        TextBox {
          Layout.fillWidth: true
          dense: true
          text: dialog.subject
          onTextChanged: dialog.subject = text
        }
      }

      Editor {
        id: body
        Layout.fillWidth: true
        Layout.preferredHeight: 200
        onSubmitted: dialog.send()
      }

      MailFooter {
        id: foot
        sendable: dialog.sendable
        onDiscarded: { dialog.discarding = true; dialog.close() }
        onSent: dialog.send()
      }
    }
  }
}
