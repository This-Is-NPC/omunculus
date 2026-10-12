pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/ui"

// ThreadView reads one thread like a mail thread: its subject, which decodes
// when the thread opens, its agent and project, then its messages, the last
// ones open and the earlier ones folded to a line each; a long thread hides
// its middle behind one fold. A message that arrives fades and rises in, and
// one that arrives out of view is counted on a pill that leads to it. Nothing
// is written until you reply: the command bar's REPLY, or Ctrl+R, opens the reply under the
// thread, and sending or Esc closes it; Esc then closes the thread.
Item {
  id: view

  required property var thread
  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  // Entry key -> whether you opened (true) or folded (false) it.
  property var toggled: ({})
  property bool showAll: false
  property bool replying: false
  // Whether Esc is the thread's: it closes the reply, or else the thread.
  property bool escapes: true
  // How many messages arrived while the end of the thread was out of view.
  property int unseen: 0
  // Whether the thread has been laid out once; what comes after arrives.
  property bool ready: false

  readonly property var entries: thread.entries
  // Long threads show their first message, a fold, and their last four.
  readonly property int hidden: showAll || entries.length <= 6 ? 0 : entries.length - 5
  readonly property var visibleEntries: hidden === 0 ? entries : [entries[0]].concat(entries.slice(entries.length - 4))
  readonly property bool atEnd: scroll.contentItem.contentY >= scroll.contentItem.contentHeight - scroll.availableHeight - 24

  function isOpen(entry) {
    if (entry.kind === "request" && entry.open)
      return true
    if (toggled[entry.key] !== undefined)
      return toggled[entry.key]
    return entries.findIndex(other => other.key === entry.key) >= entries.length - 2
  }

  function toggle(entry) {
    toggled = Object.assign({}, toggled, { [entry.key]: !isOpen(entry) })
  }

  function reply() {
    replying = true
    Qt.callLater(() => composer.focusEntry())
  }

  // The newest message in view.
  function toEnd() {
    const flick = scroll.contentItem
    flick.contentY = Math.max(0, flick.contentHeight - scroll.availableHeight)
    unseen = 0
  }

  Component.onCompleted: Qt.callLater(toEnd)
  Timer { interval: 400; running: true; onTriggered: view.ready = true }

  property int seenCount: entries.length
  onEntriesChanged: {
    const added = entries.length - seenCount
    seenCount = entries.length
    if (added <= 0)
      return
    if (atEnd)
      Qt.callLater(toEnd)
    else
      unseen += added
  }
  onAtEndChanged: if (atEnd) unseen = 0

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
        DecodeLabel {
          Layout.fillWidth: true
          value: view.thread.subject
          font.pixelSize: 16
          font.bold: true
          elide: Text.ElideRight
        }
        RowLayout {
          spacing: 10
          Label { text: "WITH " + view.thread.agent.toUpperCase(); color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 2 }
          ProjectTag { name: "· " + view.thread.project }
          ThreadState { thread: view.thread }
        }
      }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      C.ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth

        ColumnLayout {
          width: scroll.availableWidth
          spacing: 8

          Repeater {
            model: view.visibleEntries
            delegate: ColumnLayout {
              id: slot
              required property var modelData
              required property int index
              Layout.fillWidth: true
              spacing: 8

              // A message that arrives after the thread opened fades and rises in.
              transform: Translate { id: rise }
              Component.onCompleted: if (view.ready && index === view.visibleEntries.length - 1) arrive.start()
              ParallelAnimation {
                id: arrive
                NumberAnimation { target: slot; property: "opacity"; from: 0; to: 1; duration: 260 }
                NumberAnimation { target: rise; property: "y"; from: 16; to: 0; duration: 300; easing.type: Easing.OutCubic }
              }

              Entry {
                Layout.fillWidth: true
                entry: slot.modelData
                thread: view.thread.key
                expanded: view.isOpen(slot.modelData)
                onToggled: view.toggle(slot.modelData)
              }

              // The fold of a long thread's middle, after its first message.
              Chip {
                Layout.alignment: Qt.AlignHCenter
                visible: slot.index === 0 && view.hidden > 0
                icon: "more"
                text: view.hidden + " EARLIER MESSAGES"
                onClicked: view.showAll = true
              }
            }
          }
        }
      }

      NewPill {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 10 }
        count: view.unseen
        onClicked: view.toEnd()
      }
    }

    // The reply, only once asked for.
    ColumnLayout {
      id: composer
      Layout.fillWidth: true
      Layout.preferredHeight: view.replying ? implicitHeight : 0
      clip: true
      opacity: view.replying ? 1 : 0
      spacing: 10
      Behavior on Layout.preferredHeight { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 160 } }

      function focusEntry() { editor.focusEntry() }
      function send() {
        if (editor.text.trim() === "")
          return
        Mail.reply(view.thread.key, editor.take(), files.take())
        view.replying = false
      }

      Kicker { Layout.fillWidth: true; text: "reply to " + view.thread.agent }
      Editor {
        id: editor
        Layout.fillWidth: true
        Layout.preferredHeight: 96
        placeholderText: "what you have to say"
        onSubmitted: composer.send()
      }
      DialogFooter {
        FilePicker { id: files; Layout.fillWidth: true }
        primaryText: "SEND"
        primaryIcon: "enter"
        primaryEnabled: editor.text.trim() !== ""
        onCancelled: view.replying = false
        onAccepted: composer.send()
      }
    }
  }

  Shortcut { sequence: "Ctrl+R"; onActivated: view.reply() }
  Connections {
    target: Mail
    function onReplyRequested() { view.reply() }
    function onDecisionRequested() { view.toEnd() }
  }
  Shortcut {
    sequence: "Escape"
    enabled: view.escapes
    onActivated: view.replying ? view.replying = false : Mail.close()
  }
}
