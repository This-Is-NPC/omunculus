pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Breakpoints.js" as Breakpoints

// PageBar is the command bar over a page, or beside a TabRail's head: the
// commands of the page on screen, which slide in when the page changes,
// ranked. BACK stands first, apart; then the page's main action, solid, on the
// left; across a gap, on the right, the others, outlined, the guarded ones
// last (CommandRow); and at its end the page's readout, which gives way first.
// When the names do not fit, BACK shows only its chevron and the actions their
// short names, or, those too wide, each but the main one only its icon; then
// the lowest ranked actions move into the menu of a `⋯` button at the end.
// BACK and the main action never move. On a narrow window, where the rail is
// hidden, the page switcher (`pageSwitcher`) stands in for it.
Rectangle {
  id: bar

  // [{text, short, icon, tip, role, tone, group, checked, enabled, run,
  // shown}], in order; role is "back", "primary", "guarded" or left out.
  property var commands: []
  // Changes when the page does, so the commands arrive again.
  property int section: 0
  // What the page counts, as "7 CONVERSATIONS", at the bar's end; "" for none.
  property string readout: ""
  // The app's pages ([{name}]) and the one on screen, which the page switcher
  // lists on a narrow window when `pageSwitcher` is set.
  property var pages: []
  property int current: 0
  property bool pageSwitcher: false

  // A page picked in the page switcher.
  signal pageChosen(int index)

  readonly property bool narrow: Breakpoints.size(Window.width) === "narrow"
  readonly property var shown: commands.filter(command => command.shown !== false)
  readonly property var back: shown.find(command => command.role === "back") || null
  readonly property var actions: shown.filter(command => command.role !== "back")
  readonly property bool switching: pageSwitcher && narrow && pages.length > 0
  readonly property real control: Breakpoints.target(Window.width)
  // The least gap between the main action and the others.
  readonly property real gap: 24
  // The room the actions have beside BACK as only its chevron and its rule,
  // and the switcher.
  readonly property real room: width - 16 - (back !== null ? control + 21 : 0) - (switching ? switcher.width + 10 : 0) - gap
  // The room the readout takes with its rule.
  readonly property real readoutRoom: readoutMeasure.implicitWidth + 21
  // Shown while BACK as its chevron and the actions as icons, the main one
  // named, still fit beside it.
  readonly property bool readoutShown: readout !== "" && contextual.widthOf(contextual.ranked, "icon") + readoutRoom <= room

  color: Qt.alpha(Theme.background, 0.9)
  border.color: Theme.line

  onSectionChanged: if (!Theme.reducedMotion) arrive.restart()

  // BACK as named, to know the room it takes.
  TraceButton {
    id: backMeasure
    opacity: 0
    enabled: false
    dense: true
    icon: "chevron-left"
    text: bar.back ? bar.back.text : ""
  }
  // The readout, to know the room it takes.
  Label {
    id: readoutMeasure
    opacity: 0
    text: bar.readout
    font.pixelSize: 10
    font.letterSpacing: 3
  }

  // The commands slide in inside the hairline, which is never its own clip's edge.
  Item {
    anchors { fill: parent; margins: bar.border.width }
    clip: true

    RowLayout {
      anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
      spacing: Theme.space.gap

      TraceButton {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: contextual.tight || bar.narrow ? bar.control : implicitWidth
        visible: bar.back !== null
        dense: true
        role: "navigation"
        icon: "chevron-left"
        text: bar.back && !contextual.tight && !bar.narrow ? bar.back.text : ""
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
        MenuPopup {
          id: pageMenu
          entries: bar.pages.map((page, index) => ({
            text: String(index + 1).padStart(2, "0") + "  " + page.name.toUpperCase(),
            chosen: index === bar.current
          }))
          onPicked: index => bar.pageChosen(index)
        }
      }

      CommandRow {
        id: contextual
        Layout.alignment: Qt.AlignVCenter
        Layout.fillWidth: true
        spread: true
        commands: bar.actions
        iconsWhenTight: true
        overflows: true
        // Named while the names leave BACK its name.
        room: Math.max(0, bar.room - (bar.back !== null && !bar.narrow ? backMeasure.implicitWidth - bar.control : 0) - (bar.readoutShown ? bar.readoutRoom : 0))
        reserve: bar.control + 10
        transform: Translate { id: shift }
      }

      // The actions with no room in the bar.
      ActionMenu {
        id: more
        readonly property var listed: contextual.overflow.filter(command => command.enabled !== false)
        Layout.alignment: Qt.AlignVCenter
        visible: contextual.overflow.length > 0
        tip: "more commands"
        items: more.listed.map((command, index) => ({ id: String(index), icon: command.icon || "", text: command.text,
          guarded: command.role === "guarded", chosen: !!command.checked }))
        onChosen: id => more.listed[Number(id)].run()
      }

      Rectangle {
        visible: bar.readoutShown
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 1
        implicitHeight: 20
        color: Theme.line
      }
      Label {
        visible: bar.readoutShown
        Layout.alignment: Qt.AlignVCenter
        Layout.rightMargin: Theme.space.line
        text: bar.readout
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 3
      }

      ParallelAnimation {
        id: arrive
        NumberAnimation { target: contextual; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { target: shift; property: "x"; from: 16; to: 0; duration: 260; easing.type: Easing.OutCubic }
      }
    }
  }
}
