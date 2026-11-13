pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints

// CommandBar is the mailbox's one row of actions, under the masthead, as a
// mail client keeps them: on the list MARK ALL READ; with a thread open
// ARCHIVE (MOVE TO INBOX from the archive) and MARK UNREAD. COMPOSE is the
// folder rail's. Moving between threads and closing one are
// the thread's own, in its head; folding a column is the column's. Each action
// says its name while the names fit; otherwise every one but the main one shows
// only its icon, its name in the tip. The search sits at the end.
Item {
  id: bar

  // "list", or "thread" while a thread is open.
  property string place: "list"
  // Whether the window is narrow, and the search sits over the list instead.
  property bool narrow: false
  // Where the search box sits while the bar has room for it.
  readonly property alias searchSlot: slot

  implicitHeight: Math.max(40, Breakpoints.target(Window.width) + 12)

  // The actions of where you are, in order of importance.
  readonly property var commands: place === "thread" ? [
    Mail.folder === "archive"
      ? { text: "MOVE TO INBOX", icon: "import", tip: "move the thread back to the inbox", run: () => Mail.restore(Mail.selected) }
      : { text: "ARCHIVE", icon: "folder", tip: "archive the thread", run: () => Mail.archive(Mail.selected) },
    { text: "MARK UNREAD", icon: "spark", tip: "mark unread and go back to the list", enabled: !(Mail.thread && Mail.thread.job), run: () => Mail.markUnread(Mail.selected) }
  ] : [
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
