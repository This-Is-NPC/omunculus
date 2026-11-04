pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Breakpoints.js" as Breakpoints

// PageBar is the command bar beside a TabRail's head, which names the page:
// the commands of the page on screen, which slide in when the page changes,
// ranked, and at its end the app's readout. BACK stands first, apart; then
// the page's main action, solid; then the others, outlined, those of one
// `group` joined as one control whose `checked` one is lit; then, at the end,
// its tools (`place: "end"`), each only an icon with its name in the tip.
// When the names do not fit, each shows its short name; when the short names
// do not fit either, the tools and then the lowest ranked actions move into
// the menu of a `⋯` button at the end. BACK and the main action never move.
// On a narrow window BACK is only its icon, the page switcher (`pageSwitcher`)
// stands in for the hidden rail, the main action keeps its short name, every
// other command is in the menu, and the readout is only its dot, its message
// in the tip.
Rectangle {
  id: bar

  // [{text, short, icon, tip, key, role, tone, group, checked, place,
  // enabled, run, shown}], in order; role is "back", "primary", "guarded" or
  // left out.
  property var commands: []
  // Changes when the page does, so the commands arrive again.
  property int section: 0
  // The app's pages ([{name}]) and the one on screen, which the page switcher
  // lists on a narrow window when `pageSwitcher` is set.
  property var pages: []
  property int current: 0
  property bool pageSwitcher: false
  // The readout: the app's last message, whether it is an error, whether the
  // server is unreachable, and how many messages it has given.
  property string message: ""
  property bool error: false
  property bool offline: false
  property int notices: 0

  // A page picked in the page switcher.
  signal pageChosen(int index)

  readonly property bool narrow: Breakpoints.size(Window.width) === "narrow"
  readonly property var shown: commands.filter(command => command.shown !== false)
  readonly property var back: shown.find(command => command.role === "back") || null
  readonly property var tools: shown.filter(command => command.place === "end")
  // The page's actions, in their order.
  readonly property var actions: shown.filter(command => command.role !== "back" && command.place !== "end")
  readonly property bool switching: pageSwitcher && narrow && pages.length > 0

  // The room the page's actions and tools share: the bar less its margins,
  // BACK, the switcher and the readout, which keeps its dot (and the warning
  // while unreachable) on a narrow window and room for a message on a wider one.
  readonly property real gap: narrow ? 6 : 10
  readonly property real leftMargin: narrow ? 6 : 8
  readonly property real rightMargin: narrow ? 6 : 12
  readonly property real control: Breakpoints.target(Window.width)
  readonly property real readoutRoom: narrow ? 24 + (offline ? 12 + gap : 0) : 160
  readonly property real room: bar.width - leftMargin - rightMargin
    - (back ? backButton.width + 2 * gap + 1 : 0)
    - (switching ? switcher.width + gap : 0)
    - readoutRoom - 2 * gap
  readonly property real toolsWidth: tools.length > 0 ? tools.length * control + (tools.length - 1) * 6 + gap : 0
  // The tools stay while the actions fit beside them by their short names.
  readonly property bool toolsShown: !narrow && tools.length > 0 && contextual.shortWidth + toolsWidth <= room
  readonly property bool toolsMoved: tools.length > 0 && !toolsShown
  // What the menu holds: the actions that left the row, then the tools.
  readonly property var moved: contextual.overflow.concat(toolsMoved ? tools : [])

  color: Qt.alpha(Theme.background, 0.9)
  border.color: Theme.line
  clip: true

  onSectionChanged: if (!Theme.reducedMotion) arrive.restart()

  RowLayout {
    anchors { fill: parent; leftMargin: bar.leftMargin; rightMargin: bar.rightMargin }
    spacing: bar.gap

    TraceButton {
      id: backButton
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: bar.narrow ? bar.control : implicitWidth
      visible: bar.back !== null
      dense: true
      role: "navigation"
      icon: "chevron-left"
      text: bar.back && !bar.narrow ? bar.back.text : ""
      tip: bar.back ? bar.back.tip || bar.back.text.toLowerCase() : ""
      tone: Theme.dim
      onClicked: bar.back.run()
    }
    Rectangle {
      visible: bar.back !== null && (bar.actions.length > 0 || bar.switching)
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: 1
      implicitHeight: 20
      color: Theme.line
    }

    // The page on screen, which lists the pages to pick another.
    TraceButton {
      id: switcher
      Layout.alignment: Qt.AlignVCenter
      visible: bar.switching
      dense: true
      role: "action"
      icon: "chevron-down"
      text: bar.pages.length > 0 ? bar.pages[Math.max(0, Math.min(bar.current, bar.pages.length - 1))].name.toUpperCase() : ""
      tip: "pick another page"
      tone: Theme.foreground
      onClicked: pageMenu.opened ? pageMenu.close() : pageMenu.open()
      CommandMenu {
        id: pageMenu
        commands: bar.pages.map((page, index) => ({
          text: String(index + 1).padStart(2, "0") + "  " + page.name.toUpperCase(),
          checked: index === bar.current,
          run: () => bar.pageChosen(index)
        }))
      }
    }

    CommandRow {
      id: contextual
      Layout.alignment: Qt.AlignVCenter
      commands: bar.actions
      overflows: true
      onlyMain: bar.narrow
      room: Math.max(0, bar.room - (bar.toolsShown ? bar.toolsWidth : 0) - (bar.toolsMoved ? bar.control + bar.gap : 0))
      reserve: bar.toolsMoved ? 0 : bar.control + bar.gap
      transform: Translate { id: shift }
    }

    ParallelAnimation {
      id: arrive
      NumberAnimation { target: contextual; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
      NumberAnimation { target: shift; property: "x"; from: 16; to: 0; duration: 260; easing.type: Easing.OutCubic }
    }

    Item { Layout.fillWidth: true }

    StatusLine {
      Layout.alignment: Qt.AlignVCenter
      message: bar.message
      error: bar.error
      offline: bar.offline && !bar.narrow
      count: bar.notices
      // What the commands leave.
      maxWidth: bar.narrow ? 24 : Math.max(0, bar.room + bar.readoutRoom - contextual.width
        - (bar.toolsShown ? bar.toolsWidth : 0) - (more.visible ? bar.control + bar.gap : 0))
    }
    // Unreachable, on a narrow window: the warning alone, its word in the tip.
    Icon {
      Layout.alignment: Qt.AlignVCenter
      visible: bar.offline && bar.narrow
      name: "warning"
      size: 12
      color: Theme.warning
      implicitWidth: 12
      implicitHeight: 12
      HoverHandler { id: offlineHover }
      Hint { active: offlineHover.hovered; text: "Disconnected: the server does not answer" }
    }

    Row {
      id: toolRow
      Layout.alignment: Qt.AlignVCenter
      visible: bar.toolsShown
      spacing: 6
      Repeater {
        model: bar.tools
        delegate: IconButton {
          required property var modelData
          name: modelData.icon || "more"
          tip: modelData.tip || modelData.text
          tone: modelData.tone || Theme.primary
          enabled: modelData.enabled !== false
          opacity: enabled ? 1 : 0.35
          onClicked: modelData.run()
        }
      }
    }

    // The commands with no room in the bar.
    IconButton {
      id: more
      Layout.alignment: Qt.AlignVCenter
      visible: bar.moved.length > 0
      name: "more"
      tip: "more commands"
      highlighted: overflowMenu.opened
      onClicked: overflowMenu.opened ? overflowMenu.close() : overflowMenu.open()
      CommandMenu {
        id: overflowMenu
        commands: bar.moved
      }
    }
  }
}
