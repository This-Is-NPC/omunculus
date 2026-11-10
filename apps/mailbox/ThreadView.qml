pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import "kit/ui"

// ThreadView reads one thread like a mail thread: its subject, which decodes
// when the thread opens, its agent and project, and beside them the ways to
// the thread before or after it in the list and out of it; under them what
// the thread is doing and what is yours to do, and under that the reply,
// once asked for; then its messages, newest first as mail reads, the newest
// open and the older ones folded to a line each; a long thread hides its
// middle behind one fold, above its first message at the bottom. A message
// that arrives fades and drops in on top, and one that arrives while the top
// is out of view is counted on a pill that leads to it, the messages in view
// staying where they are. Nothing is written until you reply: the command
// bar's REPLY, or Ctrl+R, opens the reply, and sending or Esc closes it; Esc
// then closes the thread.
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
  // How many messages arrived while the top of the thread was out of view.
  property int unseen: 0
  // Whether the thread has been laid out once; what comes after arrives.
  property bool ready: false

  readonly property var entries: thread.entries
  // Newest first; a long thread shows its last four, a fold, and its first.
  readonly property int hidden: showAll || entries.length <= 6 ? 0 : entries.length - 5
  readonly property var visibleEntries: {
    const newest = entries.slice().reverse()
    return hidden === 0 ? newest : newest.slice(0, 4).concat([entries[0]])
  }
  readonly property bool atTop: scroll.contentItem.contentY <= 24

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

  // Scrolls so that the bottom of `item` shows, as far as its top allows.
  function reveal(item) {
    const flick = scroll.contentItem
    const bottom = item.mapToItem(flick.contentItem, 0, item.height).y + 16
    const top = item.mapToItem(flick.contentItem, 0, 0).y
    flick.contentY = Math.max(0, Math.min(bottom - scroll.availableHeight, top - 8, flick.contentHeight - scroll.availableHeight))
  }

  // The newest message in view.
  function toTop() {
    scroll.contentItem.contentY = 0
    anchorKey = ""
    unseen = 0
  }

  Timer { interval: 400; running: true; onTriggered: view.ready = true }

  // Away from the top, the message at the top of the view stays where it is
  // while messages arrive above it and others fold or open: the message and
  // how far into it the view is are kept as you scroll, and the view goes
  // back to them when the thread's height changes. For a moment after
  // messages arrive, the scrolling is the layout's, not yours: it neither
  // moves what is kept nor counts as reaching the top.
  property string anchorKey: ""
  property real anchorOffset: 0
  Timer { id: settling; interval: 600 }

  function remember() {
    const flick = scroll.contentItem
    anchorKey = ""
    if (atTop)
      return
    for (let i = 0; i < slots.count; i++) {
      const slot = slots.itemAt(i)
      if (slot && slot.y + slot.height > flick.contentY) {
        anchorKey = slot.modelData.key
        anchorOffset = flick.contentY - slot.y
        return
      }
    }
  }

  function restore() {
    if (anchorKey === "")
      return
    for (let i = 0; i < slots.count; i++) {
      const slot = slots.itemAt(i)
      if (slot && slot.modelData.key === anchorKey) {
        const flick = scroll.contentItem
        flick.contentY = Math.max(0, Math.min(slot.y + anchorOffset, flick.contentHeight - scroll.availableHeight))
        return
      }
    }
  }

  Connections {
    target: scroll.contentItem
    function onContentYChanged() { if (!settling.running) view.remember() }
    function onContentHeightChanged() { view.restore() }
  }

  property int seenCount: entries.length
  onEntriesChanged: {
    const added = entries.length - seenCount
    seenCount = entries.length
    if (added <= 0 || anchorKey === "")
      return
    unseen += added
    settling.restart()
  }
  onAtTopChanged: if (atTop && !settling.running) unseen = 0

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
        }
      }
      // Moving to the thread before or after it in the list, and closing it,
      // as a mail client's reading pane does beside the subject.
      Row {
        Layout.alignment: Qt.AlignTop
        spacing: 6
        IconButton { name: "chevron-up"; tip: "previous thread  alt+↑"; onClicked: Mail.step(-1) }
        IconButton { name: "chevron-down"; tip: "next thread  alt+↓"; onClicked: Mail.step(1) }
        IconButton { visible: !view.back; name: "close"; tip: "close the thread  esc"; onClicked: Mail.close() }
      }
    }

    StatusPanel {
      Layout.fillWidth: true
      thread: view.thread
      onDecide: Mail.decisionRequested()
      onWriteAgain: view.reply()
    }

    // The reply, only once asked for; folded, its height is capped at none,
    // since the layout gives a child no less than its fields' own otherwise.
    ColumnLayout {
      id: composer
      Layout.fillWidth: true
      Layout.maximumHeight: Layout.preferredHeight
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
            id: slots
            model: view.visibleEntries
            delegate: ColumnLayout {
              id: slot
              required property var modelData
              required property int index
              Layout.fillWidth: true
              spacing: 8

              // A message that arrives after the thread opened fades and drops in.
              transform: Translate { id: drop }
              Component.onCompleted: if (view.ready && index === 0) arrive.start()
              ParallelAnimation {
                id: arrive
                NumberAnimation { target: slot; property: "opacity"; from: 0; to: 1; duration: 260 }
                NumberAnimation { target: drop; property: "y"; from: -16; to: 0; duration: 300; easing.type: Easing.OutCubic }
              }

              // The fold of a long thread's middle, before its first message.
              Chip {
                Layout.alignment: Qt.AlignHCenter
                visible: slot.index === view.visibleEntries.length - 1 && view.hidden > 0
                icon: "more"
                text: view.hidden + " EARLIER MESSAGES"
                onClicked: view.showAll = true
              }

              Entry {
                Layout.fillWidth: true
                entry: slot.modelData
                thread: view.thread.key
                project: view.thread.project
                expanded: view.isOpen(slot.modelData)
                onToggled: view.toggle(slot.modelData)
                onReveal: item => view.reveal(item)
              }
            }
          }
        }
      }

      NewPill {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 10 }
        above: true
        count: view.unseen
        onClicked: view.toTop()
      }
    }

  }

  Shortcut { sequence: "Ctrl+R"; onActivated: view.reply() }
  Connections {
    target: Mail
    function onReplyRequested() { view.reply() }
    function onDecisionRequested() { view.toTop() }
  }
  Shortcut {
    sequence: "Escape"
    enabled: view.escapes
    onActivated: view.replying ? view.replying = false : Mail.close()
  }
}
