pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// CommandBar is the mailbox's one row of commands, under the masthead, as a
// mail client keeps them: the new thread first and always in its place; then
// what fits where you are — the list's commands, or, with a thread open, the
// ones that act on it — which slide in when the place changes; the search in
// the middle; and last, apart, how the window shows the folders and the
// threads. Wide, each command says its name beside its icon; narrower, only
// the icon shows, its name in the tip.
Item {
  id: bar

  // "list", or "thread" while a thread is open.
  property string place: "list"
  property bool compact: false
  property bool foldersShown: true
  property bool threadsShown: true
  // Whether the view's toggles show: not on a narrow window.
  property bool toggles: true
  readonly property var thread: Mail.thread
  readonly property alias search: searchBox

  signal compose()
  signal reply()
  signal step(int by)
  signal toggleFolders()
  signal toggleThreads()
  signal searchLeft()

  implicitHeight: 40

  // A label, or none while compact.
  function named(text) { return bar.compact ? "" : text }

  RowLayout {
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
    spacing: 8

    TraceButton {
      dense: true
      role: "primary"
      icon: "plus"
      text: bar.named("NEW THREAD")
      Layout.preferredWidth: bar.compact ? 32 : implicitWidth
      tip: "new thread  ctrl+n"
      enabled: Mail.connected
      onClicked: bar.compose()
    }

    Rule {}

    // The commands of where you are; each place's slide in when it comes.
    Item {
      Layout.preferredWidth: contextual.implicitWidth
      Layout.preferredHeight: 28
      Row {
        id: contextual
        spacing: 6
        transform: Translate { id: shift }
        Component.onCompleted: arrive.start()

        // The list's.
        TraceButton {
          visible: bar.place === "list"
          dense: true
          role: "progress"
          icon: "check"
          text: bar.named("MARK ALL READ")
          width: bar.compact ? 32 : implicitWidth
          tip: "mark every thread shown read"
          enabled: Mail.shown.some(thread => Mail.isUnread(thread))
          onClicked: Mail.markAllRead()
        }

        // The open thread's.
        TraceButton {
          visible: bar.place === "thread"
          dense: true
          role: "primary"
          icon: "enter"
          text: bar.named("REPLY")
          width: bar.compact ? 32 : implicitWidth
          tip: "reply to " + (bar.thread ? bar.thread.agent : "") + "  ctrl+r"
          onClicked: bar.reply()
        }
        TraceButton {
          visible: bar.place === "thread" && bar.thread !== null && bar.thread.waiting.length > 0
          dense: true
          role: "progress"
          tone: Theme.warning
          icon: "warning"
          text: bar.named("DECIDE")
          width: bar.compact ? 32 : implicitWidth
          tip: "what the thread waits on you for"
          onClicked: Mail.decisionRequested()
        }
        TraceButton {
          visible: bar.place === "thread"
          dense: true
          role: "progress"
          icon: "spark"
          text: bar.named("MARK UNREAD")
          width: bar.compact ? 32 : implicitWidth
          tip: "mark unread and go back to the list"
          onClicked: Mail.markUnread(Mail.selected)
        }
        IconButton { visible: bar.place === "thread"; name: "chevron-up"; tip: "previous thread  alt+↑"; onClicked: bar.step(-1) }
        IconButton { visible: bar.place === "thread"; name: "chevron-down"; tip: "next thread  alt+↓"; onClicked: bar.step(1) }
        IconButton { visible: bar.place === "thread"; name: "close"; tip: "close the thread  esc"; onClicked: Mail.close() }
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
    }

    Item { Layout.fillWidth: true }

    SearchBox {
      id: searchBox
      Layout.preferredWidth: bar.compact ? 160 : 280
      onLeave: bar.searchLeft()
    }

    Rule { visible: bar.toggles }

    // How the window shows the folders and the threads.
    IconButton {
      visible: bar.toggles
      name: "folder"
      tip: (bar.foldersShown ? "fold" : "unfold") + " the folders  ctrl+b"
      highlighted: bar.foldersShown
      onClicked: bar.toggleFolders()
    }
    IconButton {
      visible: bar.toggles
      name: "list"
      tip: (bar.threadsShown ? "hide" : "show") + " the threads  ctrl+l"
      highlighted: bar.threadsShown
      onClicked: bar.toggleThreads()
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

  // A short upright hairline between the groups of commands.
  component Rule: Rectangle {
    Layout.preferredHeight: 18
    Layout.leftMargin: 4
    Layout.rightMargin: 4
    implicitWidth: 1
    color: Theme.line
  }
}
