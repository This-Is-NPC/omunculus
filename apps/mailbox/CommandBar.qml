pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// CommandBar is the mailbox's one row of actions, under the masthead, as a
// mail client keeps them, ranked: the main action of where you are solid,
// then the others outlined, in order of importance, which slide in when the
// place changes, and the search at the end. On the list the main action is a
// new thread. With a thread open it is the reply, unless the thread waits on
// a decision of yours: then nothing in it moves until you decide, so DECIDE
// leads, in the warning tone, and the reply follows. Moving between threads
// and closing one are the thread's own, in its head; folding a column is the
// column's. Each action says its name while the names fit; otherwise every
// one but the main one shows only its icon, its name in the tip.
Item {
  id: bar

  // "list", or "thread" while a thread is open.
  property string place: "list"
  // Whether the window is narrow, and the search sits over the list instead.
  property bool narrow: false
  readonly property var thread: Mail.thread
  readonly property bool deciding: thread !== null && thread.waiting.length > 0
  // Where the search box sits while the bar has room for it.
  readonly property alias searchSlot: slot

  signal compose()
  signal reply()

  implicitHeight: 40

  readonly property var newThread: ({ text: "NEW THREAD", icon: "plus", tip: "new thread  ctrl+n", enabled: Mail.connected, run: () => bar.compose() })
  // The actions of where you are, in order of importance.
  readonly property var commands: place === "thread" ? [
    { text: "DECIDE", icon: "warning", role: "primary", tone: Theme.warning, tip: "what the thread waits on you for",
      shown: deciding, run: () => Mail.decisionRequested() },
    { text: "REPLY", icon: "enter", role: deciding ? "" : "primary", tip: "reply to " + (thread ? thread.agent : "") + "  ctrl+r", run: () => bar.reply() },
    { text: "MARK UNREAD", icon: "spark", tip: "mark unread and go back to the list", run: () => Mail.markUnread(Mail.selected) },
    newThread
  ].filter(command => command.shown !== false) : [
    Object.assign({ role: "primary" }, newThread),
    { text: "MARK ALL READ", icon: "check", tip: "mark every thread shown read", enabled: Mail.shown.some(thread => Mail.isUnread(thread)), run: () => Mail.markAllRead() }
  ]

  RowLayout {
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
    spacing: 8

    CommandRow {
      id: contextual
      Layout.alignment: Qt.AlignVCenter
      commands: bar.commands
      room: bar.width - (bar.narrow ? 0 : slot.width) - 24
      iconsWhenTight: true
      transform: Translate { id: shift }
    }

    ParallelAnimation {
      id: arrive
      NumberAnimation { target: contextual; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: shift; property: "x"; from: 12; to: 0; duration: 220; easing.type: Easing.OutCubic }
    }
    Connections {
      target: bar
      function onPlaceChanged() { arrive.restart() }
    }

    Item { Layout.fillWidth: true }

    // The search, unless the window is narrow and keeps it over the list.
    Item {
      id: slot
      visible: !bar.narrow
      Layout.preferredWidth: bar.width >= 1060 ? 280 : 200
      Layout.preferredHeight: 30
    }
  }

  // The bar's own rule, under it, fading out as the masthead's does.
  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 1
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0; color: Theme.line }
      GradientStop { position: 1; color: "transparent" }
    }
  }
}
