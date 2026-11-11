pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ThreadView reads one thread as a mail client does: its subject and label,
// who it is with, and the ways to the thread before or after and out of it;
// then its messages stacked oldest first, the latest open and the older ones
// folded to a line each. A reply is written under them, once asked for by a
// message's Reply (or Ctrl+R, for the latest): it quotes the message it
// answers, so it is plain what it answers. A request of the agent that waits
// for you is answered by replying to it, or, replying to any other message of
// the thread, to the newest request waiting; with none waiting the reply is a
// message to the agent. Sending or Esc closes the reply; Esc then closes the
// thread.
Item {
  id: view

  required property var thread
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // Message key -> whether you opened (true) or folded (false) it.
  property var toggled: ({})
  // The message being replied to, "" while no reply is being written.
  property string replyKey: ""
  // Whether Esc is the thread's: it closes the reply, or else the thread.
  property bool escapes: true

  readonly property var messages: thread.messages
  readonly property bool replying: replyKey !== ""
  readonly property var target: replying ? Mailbox.replyTarget(thread, replyKey) : null
  // The message it answers, quoted as {head, lines}, or null.
  readonly property var quote: target && target.quoted ? Mailbox.quoted(target.quoted, Mail.stamp(target.quoted.at)) : null
  property bool quoteAll: false

  function isOpen(message, index) {
    if (message.pending)
      return true
    if (toggled[message.key] !== undefined)
      return toggled[message.key]
    return index === messages.length - 1
  }

  function toggle(message, index) {
    toggled = Object.assign({}, toggled, { [message.key]: !isOpen(message, index) })
  }

  // Opens the reply to `key`, the latest message when none is given.
  function reply(key) {
    if (messages.length === 0)
      return
    replyKey = key || messages[messages.length - 1].key
    quoteAll = false
    Qt.callLater(() => { editor.focusEntry(); toEnd() })
  }

  // Scrolls to the latest message, and keeps there while the messages settle
  // to their height, until you scroll or a moment passes.
  function toEnd() {
    landing = true
    settle.restart()
    scroll.scrollTo(scroll.contentHeight)
  }
  property bool landing: false

  function send() {
    if (editor.text.trim() === "")
      return
    const request = target.request
    Mail.reply(thread.key, request, editor.take(), request === "" ? footer.take() : [])
    replyKey = ""
  }

  // A thread that opens, or gets a message, is read from its latest.
  property int seenCount: messages.length
  onMessagesChanged: {
    if (messages.length !== seenCount) {
      seenCount = messages.length
      Qt.callLater(toEnd)
    }
  }
  Component.onCompleted: Qt.callLater(() => {
    toEnd()
    // The thread holds the keyboard, for PgUp/PgDn, unless a text field has it.
    const held = Window.activeFocusItem
    if (!held || !held.hasOwnProperty("cursorPosition"))
      scroll.forceActiveFocus()
  })

  Timer { id: settle; interval: 600; onTriggered: view.landing = false }

  ColumnLayout {
    anchors.fill: parent
    spacing: 14

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list  esc"; onClicked: Mail.close() }
      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: 6
        RowLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          spacing: 12
          Label {
            Layout.fillWidth: true
            text: view.thread.subject
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
          }
          MailLabel { kind: view.thread.label }
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: 10
          Label { Layout.fillWidth: true; text: view.thread.with.text; color: Theme.dim; font.pixelSize: 11; elide: Text.ElideRight }
        }
      }
      Row {
        Layout.alignment: Qt.AlignTop
        spacing: 6
        IconButton { name: "chevron-up"; tip: "previous thread  alt+↑"; onClicked: Mail.step(-1) }
        IconButton { name: "chevron-down"; tip: "next thread  alt+↓"; onClicked: Mail.step(1) }
        IconButton { visible: !view.back; name: "close"; tip: "close the thread  esc"; onClicked: Mail.close() }
      }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

    // A Flickable of its own: the wheel scrolls it wherever the pointer is
    // over it, and PgUp/PgDn/Home/End when it holds the keyboard.
    ScrollPage {
      id: scroll
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentWidth: width
      contentHeight: column.implicitHeight
      onContentHeightChanged: if (view.landing) scrollTo(contentHeight)
      onMovementStarted: view.landing = false
      C.ScrollBar.vertical: C.ScrollBar {}

      ColumnLayout {
        id: column
        width: scroll.width
        spacing: 8

        Repeater {
          model: view.messages
          delegate: Message {
            required property var modelData
            required property int index
            Layout.fillWidth: true
            message: modelData
            thread: view.thread.key
            project: view.thread.project
            expanded: view.isOpen(modelData, index)
            latest: index === view.messages.length - 1
            replying: view.replying
            onToggled: view.toggle(modelData, index)
            onReplyTo: view.reply(modelData.key)
            onForwardIt: Mail.compose(Mailbox.forward(view.thread, modelData))
          }
        }
      }
    }

    // The reply, under the messages and outside their scrolling, so its
    // actions stay in view while you type. It quotes what it answers, as mail
    // does; only your own words are sent.
    SurfaceFrame {
      Layout.fillWidth: true
      visible: view.replying
      Layout.preferredHeight: writing.implicitHeight + 28
      variant: "outline"
      active: true

      ColumnLayout {
        id: writing
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
        spacing: 10

        Label {
          Layout.fillWidth: true
          text: "To: " + view.thread.with.text + "   ·   " + Mailbox.re(view.thread.subject)
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
        Editor {
          id: editor
          Layout.fillWidth: true
          Layout.preferredHeight: 96
          placeholderText: "your reply"
          onSubmitted: view.send()
        }
        // The quoted original, folded after a few lines.
        ColumnLayout {
          Layout.fillWidth: true
          visible: view.quote !== null
          spacing: 4
          Label {
            Layout.fillWidth: true
            text: view.quote ? view.quote.head : ""
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          Label {
            Layout.fillWidth: true
            text: view.quote ? (view.quoteAll ? view.quote.lines : view.quote.lines.slice(0, 4)).join("\n") : ""
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          Chip {
            visible: view.quote !== null && view.quote.lines.length > 4
            icon: "more"
            text: view.quoteAll ? "LESS" : "MORE"
            onClicked: view.quoteAll = !view.quoteAll
          }
        }
        MailFooter {
          id: footer
          attachable: view.target !== null && view.target.request === ""
          sendable: editor.text.trim() !== ""
          onDiscarded: view.replyKey = ""
          onSent: view.send()
        }
      }
    }
  }

  Shortcut { sequence: "Ctrl+R"; onActivated: view.reply("") }
  Connections {
    target: Mail
    function onReplyRequested(key) { view.reply(key) }
  }
  Shortcut {
    sequence: "Escape"
    enabled: view.escapes
    onActivated: view.replying ? view.replyKey = "" : Mail.close()
  }
}
