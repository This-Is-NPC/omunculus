pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// CommandBar is the mailbox's one row of actions, under the masthead, as a
// mail client keeps them: the new thread first and always in its place, then
// what fits where you are — the list's commands, or, with a thread open, the
// ones that act on it — which slide in when the place changes, and the search
// at the end. How the columns show is not here: each column folds from its
// own head. Wide, each command says its name beside its icon; narrower, only
// the icon shows, its name in the tip; narrow, only the essential commands
// show and the rest wait behind "more".
Item {
  id: bar

  // "list", or "thread" while a thread is open.
  property string place: "list"
  // "wide", "compact" or "narrow".
  property string fit: "wide"
  readonly property var thread: Mail.thread
  // Where the search box sits while the bar has room for it.
  readonly property alias searchSlot: slot

  signal compose()
  signal reply()
  signal step(int by)

  implicitHeight: 40

  // The commands of where you are, in order of importance: each its text,
  // icon, role, tone, whether it shows only its icon, whether it stays when
  // the bar is narrow, whether it can run, and what it runs.
  readonly property var commands: place === "thread" ? [
    { text: "REPLY", icon: "enter", role: "primary", tip: "reply to " + (thread ? thread.agent : "") + "  ctrl+r", essential: true, run: () => bar.reply() },
    { text: "DECIDE", icon: "warning", tone: Theme.warning, tip: "what the thread waits on you for", essential: true,
      shown: thread !== null && thread.waiting.length > 0, run: () => Mail.decisionRequested() },
    { text: "MARK UNREAD", icon: "spark", tip: "mark unread and go back to the list", run: () => Mail.markUnread(Mail.selected) },
    { text: "PREVIOUS", icon: "chevron-up", iconOnly: true, tip: "previous thread  alt+↑", run: () => bar.step(-1) },
    { text: "NEXT", icon: "chevron-down", iconOnly: true, tip: "next thread  alt+↓", run: () => bar.step(1) },
    { text: "CLOSE", icon: "close", iconOnly: true, tip: "close the thread  esc", run: () => Mail.close() }
  ] : [
    { text: "MARK ALL READ", icon: "check", tip: "mark every thread shown read", enabled: Mail.shown.some(thread => Mail.isUnread(thread)), run: () => Mail.markAllRead() }
  ]
  readonly property var present: commands.filter(command => command.shown !== false)
  readonly property var inBar: fit === "narrow" ? present.filter(command => command.essential) : present
  readonly property var behind: fit === "narrow" ? present.filter(command => !command.essential) : []

  RowLayout {
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
    spacing: 8

    TraceButton {
      dense: true
      role: "primary"
      icon: "plus"
      text: bar.fit === "wide" ? "NEW THREAD" : ""
      Layout.preferredWidth: bar.fit === "wide" ? implicitWidth : 32
      tip: "new thread  ctrl+n"
      enabled: Mail.connected
      onClicked: bar.compose()
    }

    Rectangle { Layout.preferredHeight: 18; Layout.leftMargin: 4; Layout.rightMargin: 4; implicitWidth: 1; color: Theme.line }

    // The commands of where you are; each place's slide in when it comes.
    Row {
      id: contextual
      spacing: 6
      transform: Translate { id: shift }

      Repeater {
        model: bar.inBar
        delegate: TraceButton {
          required property var modelData
          readonly property bool labelled: bar.fit === "wide" && !modelData.iconOnly
          dense: true
          role: modelData.role || "progress"
          tone: modelData.tone || (role === "guarded" ? Theme.error : Theme.primary)
          icon: modelData.icon
          text: labelled ? modelData.text : ""
          width: labelled ? implicitWidth : 32
          tip: modelData.tip
          enabled: modelData.enabled !== false
          onClicked: modelData.run()
        }
      }

      IconButton {
        visible: bar.behind.length > 0
        name: "more"
        tip: "more"
        onClicked: more.open()
        MoreMenu {
          id: more
          entries: bar.behind
          onPicked: index => bar.behind[index].run()
        }
      }
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
      visible: bar.fit !== "narrow"
      Layout.preferredWidth: bar.fit === "wide" ? 280 : 200
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
