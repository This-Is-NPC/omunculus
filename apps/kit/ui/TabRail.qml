pragma ComponentBehavior: Bound
import QtQuick
import "Breakpoints.js" as Breakpoints

// TabRail is an app's pages in a fixed order down the left edge, the one on
// screen marked in its place. While its names take at most a fifth of the
// window's width it always shows them beside their numbers; on a window
// short of that, folded, it takes only the width of the numbers, and under
// the pointer or with the keyboard in it, it unfolds as an opaque panel over
// what is beside it; on a narrow one it is hidden and takes no width,
// the bar's page switcher choosing the pages instead. One click chooses a
// page and folds the rail, which stays folded until the pointer has left and
// come back; Esc folds it too. Each page is a stop of the Tab chain: ↑ ↓ Home
// End move the keyboard along the rail, Enter or Space chooses.
Item {
  id: rail

  // [{name}], in order.
  required property var tabs
  property int current: 0
  // The height of the command bar beside the rail; room for touch-sized
  // controls on a narrow window.
  readonly property real headHeight: Theme.size.control + (size === "narrow" ? Theme.space.gap : 0)

  // Chosen by a click or Enter; Esc folded it, so the page takes the keyboard.
  signal chosen(int index)
  signal escaped()

  readonly property real tabHeight: 36
  readonly property real gap: 8
  readonly property real unfoldedWidth: 220
  readonly property real windowWidth: Window.window ? Window.window.width : 0
  readonly property string size: Breakpoints.size(windowWidth)
  // A character of a tab, monospaced, its tracking included.
  readonly property real advance: tabFont.advanceWidth("0")
  FontMetrics { id: tabFont; font.family: Theme.fontFamily; font.pixelSize: 12; font.letterSpacing: 2 }
  // The width of a tab with its number and the longest name.
  readonly property real namedWidth: Math.ceil(2 * Theme.space.cell + Theme.space.gap
    + advance * (2 + tabs.reduce((most, tab) => Math.max(most, String(tab.name).length), 0)))
  // The window has room to keep the names on screen.
  readonly property bool wide: size !== "narrow" && windowWidth >= 5 * namedWidth
  // The width it keeps folded, which what is beside it leaves room for.
  readonly property real foldedWidth: size === "narrow" ? 0 : wide ? namedWidth : 52
  // How many of its tabs hold the keyboard: one, or none.
  property int focusedTabs: 0
  // Folded by a choice or Esc until the pointer and the keyboard have left.
  property bool dismissed: false
  readonly property bool engaged: hover.hovered || focusedTabs > 0
  readonly property bool unfolded: !wide && engaged && !dismissed
  readonly property bool named: wide || unfolded
  readonly property int motion: Theme.reducedMotion ? 0 : 160

  onEngagedChanged: if (!engaged) dismissed = false
  function fold() { dismissed = true }
  function escapeRail() {
    fold()
    escaped()
  }
  Shortcut {
    enabled: rail.unfolded
    sequence: "Escape"
    onActivated: rail.escapeRail()
  }

  HoverHandler { id: hover }

  // Gives the keyboard to the tab at `index`, kept within the rail.
  function reach(index) {
    tabRepeater.itemAt(Math.max(0, Math.min(tabs.length - 1, index))).forceActiveFocus(Qt.TabFocusReason)
  }

  visible: size !== "narrow"
  // Wide enough that the pointer on the unfolded panel is still over the rail.
  width: unfolded ? unfoldedWidth : foldedWidth
  height: tabs.length * tabHeight + (tabs.length - 1) * gap

  // The opaque panel an unfolded rail is, over the page.
  Rectangle {
    visible: rail.unfolded
    x: -8
    y: -8
    width: rail.unfoldedWidth + 16
    height: rail.height + 16
    color: Theme.background
    border.color: Qt.alpha(Theme.foreground, 0.35)
  }

  Repeater {
    id: tabRepeater
    model: rail.tabs
    delegate: Rectangle {
      id: tab
      required property var modelData
      required property int index
      readonly property bool head: index === rail.current
      readonly property color tone: head ? Theme.primary : pointer.containsMouse ? Theme.foreground : Theme.dim

      y: index * (rail.tabHeight + rail.gap)
      width: rail.unfolded ? rail.unfoldedWidth : rail.foldedWidth
      height: rail.tabHeight
      Behavior on width { NumberAnimation { duration: rail.motion; easing.type: Easing.OutCubic } }

      color: head ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.08)) : Theme.background
      border.color: head ? Qt.alpha(Theme.primary, 0.7) : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.35) : Theme.line
      clip: true

      // The keyboard reaches each page; Enter or Space chooses it.
      activeFocusOnTab: true
      onActiveFocusChanged: rail.focusedTabs += activeFocus ? 1 : -1
      Keys.onReturnPressed: pointer.choose()
      Keys.onSpacePressed: pointer.choose()
      Keys.onEscapePressed: rail.escapeRail()
      Keys.onUpPressed: rail.reach(tab.index - 1)
      Keys.onDownPressed: rail.reach(tab.index + 1)
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Home)
          rail.reach(0)
        else if (event.key === Qt.Key_End)
          rail.reach(rail.tabs.length - 1)
        else
          return
        event.accepted = true
      }
      FocusRing {}

      Row {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: rail.named ? Theme.space.cell : (rail.foldedWidth - digit.implicitWidth) / 2 }
        spacing: Theme.space.gap
        Label {
          id: digit
          anchors.verticalCenter: parent.verticalCenter
          text: String(tab.index + 1).padStart(2, "0")
          color: tab.tone
          font.pixelSize: 12
          font.letterSpacing: 2
        }
        Label {
          anchors.verticalCenter: parent.verticalCenter
          visible: rail.named
          // Elided short of the tab's right edge.
          width: Math.max(0, Math.min(implicitWidth, tab.width - 2 * Theme.space.cell - digit.width - parent.spacing))
          elide: Text.ElideRight
          text: tab.modelData.name.toUpperCase()
          color: tab.tone
          font.pixelSize: 12
          font.letterSpacing: 2
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        function choose() {
          rail.fold()
          rail.chosen(tab.index)
        }
        onClicked: choose()
      }
    }
  }
}
