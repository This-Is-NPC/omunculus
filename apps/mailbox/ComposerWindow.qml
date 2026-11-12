pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Composers.js" as Composers
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints

// ComposerWindow is one message being written: a new one, a reply or a
// forward, the same window for all. Its bar holds the title, which is the
// subject, and minimize, expand and close; under it To (RecipientField), the
// Subject, a body that fills the window's height and scrolls past it, the
// reply's quoted message behind MORE, and the footer with Attach, the files,
// DISCARD and SEND, the one solid action, in one row. The ComposerDock places it and sets its
// `shape`: "window" docked, "tab" only its bar, "full" expanded, "screen" a
// phone's, under the tab strip, and "hidden". A composer that is not shown
// keeps its words. Ctrl+Enter sends, Esc minimizes. Closing with something
// written asks whether to keep it as a draft or discard it.
FocusScope {
  id: composer

  // The composer's record, as Composers.open makes it.
  required property var entry
  property string shape: "window"
  // On a phone, where the bar sits in the strip.
  property real barX: 0
  property real barWidth: width

  readonly property bool tab: shape === "tab"
  readonly property bool phone: shape === "screen"
  readonly property bool shown: shape !== "hidden"
  readonly property bool reply: entry.kind === "reply"
  readonly property string subject: subjectBox.text
  readonly property real bar: phone ? Breakpoints.target(Window.width) : Theme.size.strip
  readonly property var thread: reply ? Mail.threads[entry.thread] || null : null
  readonly property var target: Mailbox.sendTarget(recipients.chosen.length > 0 ? recipients.chosen[0] : null, Mail.defaultRecipient())
  readonly property bool written: Composers.written(entry, { subject: subjectBox.text, body: editor.text, files: foot.fileCount })
  readonly property bool sendable: Mail.connected && (reply
    ? thread !== null && editor.text.trim() !== "" && recipients.chosen.length > 0
    : target !== null && (subjectBox.text.trim() !== "" || editor.text.trim() !== ""))
  property bool quoteAll: false

  // The bar's words: the subject being written.
  readonly property string heading: Composers.title(subjectBox.text)

  visible: shown

  function focusEntry() {
    if (!reply && recipients.chosen.length === 0)
      recipients.focusEntry()
    else
      editor.focusEntry()
  }

  function send() {
    if (!sendable)
      return
    if (reply) {
      const request = entry.request
      const text = editor.take()
      const files = foot.take()
      const mine = Mailbox.counterparts(thread).map(item => item.address)
      // The thread's own accounts are answered in it; any other is written to in a message of its own.
      if (recipients.chosen.some(item => mine.includes(item.address)))
        Mail.reply(thread.key, request, subjectBox.text, text, files)
      for (const other of recipients.chosen.filter(item => !mine.includes(item.address)))
        Mail.send(other.project, other.agent, subjectBox.text, text, files, "", true)
    } else {
      Mail.send(target.project, target.agent, subjectBox.text, editor.take(), foot.take(), entry.draft)
    }
    Mail.closeComposer(entry.id)
  }

  // Closes it, asking first when something is written.
  function close() {
    if (written)
      confirm.open()
    else
      leave(false)
  }

  // Closes it, keeping what is written as a draft, or dropping its draft.
  function leave(keep) {
    if (keep) {
      const first = recipients.chosen.length > 0 ? recipients.chosen[0] : null
      Mail.saveDraft({ id: entry.draft, project: first ? first.project : "", agent: first ? first.agent : "", subject: subjectBox.text, body: editor.text })
    } else if (entry.draft !== "") {
      Mail.discardDraft(entry.draft)
    }
    Mail.closeComposer(entry.id)
  }

  Component.onCompleted: {
    subjectBox.text = entry.subject
    editor.text = entry.body
    Qt.callLater(focusEntry)
  }
  onShapeChanged: if (shape !== "tab" && shape !== "hidden") Qt.callLater(focusEntry)

  Keys.onEscapePressed: Mail.minimizeComposer(entry.id)
  Shortcut { sequence: "Ctrl+Return"; enabled: composer.activeFocus && composer.shown && !composer.tab; onActivated: composer.send() }
  Shortcut { sequence: "Ctrl+Enter"; enabled: composer.activeFocus && composer.shown && !composer.tab; onActivated: composer.send() }

  Rectangle {
    y: composer.phone ? composer.bar : 0
    width: parent.width
    height: parent.height - y
    color: Theme.background
    border.color: composer.activeFocus ? Theme.primary : Theme.line
  }

  // The bar: the title, and the three ways to treat the window.
  Item {
    id: head
    x: composer.phone ? composer.barX : 0
    width: composer.phone ? composer.barWidth : parent.width
    height: composer.bar

    Rectangle {
      anchors.fill: parent
      color: composer.tab || composer.phone ? Qt.alpha(Theme.foreground, composer.activeFocus ? 0.06 : 0.03) : "transparent"
      border.color: composer.phone ? (composer.shape === "screen" ? Theme.primary : Theme.line) : "transparent"
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: composer.tab || composer.phone ? Mail.activateComposer(composer.entry.id) : Mail.minimizeComposer(composer.entry.id)
    }
    RowLayout {
      anchors { fill: parent; leftMargin: Theme.space.gap; rightMargin: Theme.space.tight }
      spacing: Theme.space.tight
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: composer.heading
        font.bold: true
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      IconButton { visible: !composer.tab && !composer.phone; name: "minimize"; tip: "minimize  esc"; quiet: true; onClicked: Mail.minimizeComposer(composer.entry.id) }
      IconButton {
        visible: !composer.tab && !composer.phone
        name: "expand"
        tip: composer.shape === "full" ? "dock it" : "expand"
        quiet: true
        onClicked: Mail.expandComposer(composer.entry.id)
      }
      IconButton { visible: head.width >= 96; name: "close"; tip: "close"; quiet: true; onClicked: composer.close() }
    }
  }

  ColumnLayout {
    visible: !composer.tab
    anchors { fill: parent; topMargin: composer.bar + Theme.space.tight; margins: Theme.space.inset }
    spacing: Theme.space.tight

    // The fields share one label column; each is one row high.
    GridLayout {
      Layout.fillWidth: true
      columns: 2
      columnSpacing: Theme.space.gap
      rowSpacing: Theme.space.tight

      Label {
        Layout.preferredWidth: 56
        Layout.preferredHeight: Theme.size.controlDense
        Layout.alignment: Qt.AlignTop
        text: "To"
        color: Theme.dim
        font.pixelSize: 12
        verticalAlignment: Text.AlignVCenter
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.space.line
        RecipientField {
          id: recipients
          Layout.fillWidth: true
          candidates: Mail.recipients
          single: !composer.reply
          placeholder: composer.reply ? "add another" : Mailbox.hint(Mail.defaultRecipient())
          Component.onCompleted: chosen = composer.entry.to
        }
        FieldError { Layout.fillWidth: true; text: recipients.refusal }
      }

      Label {
        Layout.preferredWidth: 56
        Layout.preferredHeight: Theme.size.controlDense
        Layout.alignment: Qt.AlignTop
        text: "Subject"
        color: Theme.dim
        font.pixelSize: 12
        verticalAlignment: Text.AlignVCenter
      }
      // A reply starts with its thread's subject, "Re: ...", which can be changed like any other.
      TextBox {
        id: subjectBox
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.size.controlDense
        dense: true
        onAccepted: editor.focusEntry()
      }
    }

    ScrollPage {
      id: page
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentWidth: width
      contentHeight: words.implicitHeight

      ColumnLayout {
        id: words
        width: page.width
        spacing: Theme.space.tight

        Editor {
          id: editor
          Layout.fillWidth: true
          placeholderText: composer.reply ? "your reply" : ""
          minimumLines: 3
          minimumHeight: page.height - (quote.visible ? quote.implicitHeight + words.spacing : 0)
        }
        // The quoted original, behind MORE.
        ColumnLayout {
          id: quote
          Layout.fillWidth: true
          visible: composer.entry.quoted !== null
          spacing: Theme.space.line
          Chip {
            icon: "more"
            text: composer.quoteAll ? "HIDE QUOTE" : "MORE"
            tip: "the message this answers"
            onClicked: composer.quoteAll = !composer.quoteAll
          }
          Label {
            Layout.fillWidth: true
            visible: composer.quoteAll
            text: composer.entry.quoted ? composer.entry.quoted.head : ""
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          Label {
            Layout.fillWidth: true
            visible: composer.quoteAll
            text: composer.entry.quoted ? composer.entry.quoted.lines.join("\n") : ""
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
        }
      }
    }

    MailFooter {
      id: foot
      sendable: composer.sendable
      onDiscarded: composer.close()
      onSent: composer.send()
    }
  }

  ConfirmDialog {
    id: confirm
    title: "DISCARD THIS MESSAGE?"
    question: "What you wrote is not sent."
    confirmText: "DISCARD"
    cancelText: "KEEP WRITING"
    onConfirmed: composer.leave(false)
    Chip {
      icon: "edit"
      text: "SAVE DRAFT"
      onClicked: { confirm.close(); composer.leave(true) }
    }
  }
}
