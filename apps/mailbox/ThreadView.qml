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
    Qt.callLater(() => { editor.focusEntry(); toEnd() })
  }

  function toEnd() {
    const flick = scroll.contentItem
    flick.contentY = Math.max(0, flick.contentHeight - scroll.availableHeight)
  }

  function send() {
    if (editor.text.trim() === "")
      return
    const request = target.request
    Mail.reply(thread.key, request, editor.take(), request === "" ? files.take() : [])
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
  Component.onCompleted: Qt.callLater(toEnd)

  ColumnLayout {
    anchors.fill: parent
    spacing: 14

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list  esc"; onClicked: Mail.close() }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        RowLayout {
          Layout.fillWidth: true
          spacing: 12
          DecodeLabel {
            Layout.fillWidth: true
            value: view.thread.subject
            font.pixelSize: 16
            font.bold: true
            elide: Text.ElideRight
          }
          MailLabel { kind: view.thread.label }
        }
        RowLayout {
          spacing: 10
          Label { text: view.thread.with.text; color: Theme.dim; font.pixelSize: 11 }
          ProjectTag { name: "· " + view.thread.project }
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

    C.ScrollView {
      id: scroll
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: availableWidth

      ColumnLayout {
        width: scroll.availableWidth
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

        // The reply, quoting what it answers.
        SurfaceFrame {
          Layout.fillWidth: true
          visible: view.replying
          implicitHeight: writing.implicitHeight + 28
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
              elide: Text.ElideRight
            }
            Editor {
              id: editor
              Layout.fillWidth: true
              Layout.preferredHeight: 110
              placeholderText: "your reply"
              onSubmitted: view.send()
            }
            Rectangle {
              Layout.fillWidth: true
              visible: view.target !== null && view.target.quoted !== null
              implicitHeight: quoted.implicitHeight + 20
              color: "transparent"
              border.color: Theme.line
              Label {
                id: quoted
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                text: view.target && view.target.quoted
                  ? view.target.quoted.from.name + " wrote, " + Mail.stamp(view.target.quoted.at) + ":\n" + Mailbox.quote(view.target.quoted.text)
                  : ""
                color: Theme.dim
                font.pixelSize: 11
                wrapMode: Text.Wrap
                maximumLineCount: 8
                elide: Text.ElideRight
              }
            }
            DialogFooter {
              IconButton {
                visible: view.target !== null && view.target.request === ""
                name: "attach"
                tip: "files to send with the message"
                onClicked: files.pick()
              }
              FilePicker { id: files; Layout.fillWidth: true }
              primaryText: "SEND"
              primaryIcon: "enter"
              primaryEnabled: editor.text.trim() !== ""
              cancelText: "DISCARD"
              onCancelled: view.replyKey = ""
              onAccepted: view.send()
            }
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
    onActivated: view.replying ? view.replyKey = "" : Mail.close()
  }
}
