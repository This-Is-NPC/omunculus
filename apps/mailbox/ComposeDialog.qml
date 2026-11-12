pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ComposeDialog writes a new message as a mail client does: a header of one
// line each, To and Subject, then the message, which grows with its words;
// past the window's height the dialog scrolls. To holds one agent as a chip
// (RecipientField), found by typing or in the address book; a thread is with
// one agent, so a second is refused, saying so. To starts empty: left empty,
// the message goes to the project's default agent, which the field's hint
// names. Closing it with
// something written keeps it in Drafts; DISCARD drops it.
ModalDialog {
  id: dialog

  // The recipient, as Mailbox.person makes it, or null.
  readonly property var to: recipients.chosen.length > 0 ? recipients.chosen[0] : null
  property string subject: ""
  // The draft it was opened from, "" for a new message.
  property string draft: ""
  property bool discarding: false

  // The width of the header's labels, so the fields line up.
  readonly property int labelWidth: 64

  maxWidth: 640
  // Short of the window's edges, the dialog scrolls instead of growing.
  height: Math.min(implicitHeight, parent.height - 2 * Theme.space.page)

  // Opens it for `preset`: {draft}, or {subject, body} for a message started
  // from another.
  function start(preset) {
    const saved = preset.draft || null
    draft = saved ? saved.id : ""
    const first = saved && saved.agent !== "" ? Mailbox.person(saved.agent, saved.project) : null
    recipients.chosen = first ? [first] : []
    recipients.refusal = ""
    subject = saved ? saved.subject : preset.subject || ""
    body.text = saved ? saved.body : preset.body || ""
    discarding = false
    open()
  }

  onOpened: { panel.dialogOpen = true; if (to === null) recipients.focusEntry(); else body.focusEntry() }
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
    recipients.chosen = []
  }

  readonly property var target: Mailbox.sendTarget(to, Mail.defaultRecipient())
  readonly property bool sendable: target !== null && (subject.trim() !== "" || body.text.trim() !== "") && Mail.connected

  function send() {
    if (!sendable)
      return
    Mail.send(target.project, target.agent, subject, body.take(), foot.take(), draft)
    discarding = true
    close()
  }

  contentItem: DialogPanel {
    id: panel
    index: "01"
    title: "NEW MESSAGE"

    ScrollPage {
      id: page
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      implicitHeight: column.implicitHeight

      ColumnLayout {
        id: column
        width: page.width
        spacing: 8

        // To: the label, then the chips, the field for another and the address book.
        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Label { Layout.preferredWidth: dialog.labelWidth; text: "To"; color: Theme.dim; font.pixelSize: 12 }
          RecipientField {
            id: recipients
            Layout.fillWidth: true
            candidates: Mail.recipients
            single: true
            placeholder: Mailbox.hint(Mail.defaultRecipient())
          }
        }
        FieldError { Layout.fillWidth: true; Layout.leftMargin: dialog.labelWidth + 8; text: recipients.refusal }

        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Label { Layout.preferredWidth: dialog.labelWidth; text: "Subject"; color: Theme.dim; font.pixelSize: 12 }
          TextBox {
            Layout.fillWidth: true
            dense: true
            text: dialog.subject
            onTextChanged: dialog.subject = text
            onAccepted: body.focusEntry()
          }
        }

        Editor {
          id: body
          Layout.fillWidth: true
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
}
