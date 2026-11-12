pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// ThreadView reads one thread as a mail client does: its subject and label,
// who it is with, and the ways to the thread before or after and out of it;
// then its messages stacked oldest first, the latest open and the older ones
// folded to a line each. A message's Reply (or Ctrl+R, for the latest) opens a
// composer docked over the mailbox, so the thread stays readable beside it; Esc
// closes the thread.
Item {
  id: view

  required property var thread
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // Message key -> whether you opened (true) or folded (false) it.
  property var toggled: ({})
  // Whether Esc is the thread's, to close it.
  property bool escapes: true

  readonly property var messages: thread.messages

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

  // Opens the composer for a reply to `key`, the latest message when none is
  // given, to its other party, or to everyone on the thread when `all`.
  function reply(key, all) { Mail.openReply(thread, key, all) }

  // Scrolls to the latest message, and keeps there while the messages settle
  // to their height, until you scroll or a moment passes.
  function toEnd() {
    landing = true
    settle.restart()
    scroll.scrollTo(scroll.contentHeight)
  }
  property bool landing: false

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
        // The label sits beside the subject, which wraps to two lines before
        // it is cut; on a narrow window the label goes under it.
        GridLayout {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          columns: view.back ? 1 : 2
          columnSpacing: 12
          rowSpacing: 6
          Label {
            Layout.fillWidth: true
            text: view.thread.subject
            font.pixelSize: 16
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 2
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
            several: Mailbox.canReplyAll(view.thread)
            onToggled: view.toggle(modelData, index)
            onReplyTo: all => view.reply(modelData.key, all)
            onForwardIt: Mail.compose(Object.assign({ kind: "forward" }, Mailbox.forward(view.thread, modelData)))
          }
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
    onActivated: Mail.close()
  }
}
