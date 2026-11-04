pragma ComponentBehavior: Bound
import QtQuick
import "Breakpoints.js" as Breakpoints

// TabRail is an app's pages in a fixed order down the left edge, the one on
// screen marked in its place. Folded, it takes only the width of the pages'
// numbers; on a wide window it always shows their names; on a medium one,
// under the pointer or with the keyboard in it, it unfolds as an opaque panel
// over what is beside it; on a narrow one it is hidden and takes no width,
// the bar's page switcher choosing the pages instead. One click chooses a
// page and folds the rail, which stays folded until the pointer has left and
// come back; Esc folds it too.
Item {
  id: rail

  // [{name}], in order.
  required property var tabs
  property int current: 0
  // The height of the command bar beside the rail.
  readonly property real headHeight: 44

  // Chosen by a click or Enter; Esc folded it, so the page takes the keyboard.
  signal chosen(int index)
  signal escaped()

  readonly property real tabHeight: 36
  readonly property real gap: 8
  readonly property real unfoldedWidth: 220
  readonly property string size: Breakpoints.size(Window.window ? Window.window.width : 0)
  // The window is wide enough to keep the names on screen.
  readonly property bool wide: size === "wide"
  // The width it keeps folded, which what is beside it leaves room for.
  readonly property real foldedWidth: wide ? 160 : size === "medium" ? 52 : 0
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
      FocusRing {}

      Row {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: rail.named ? 12 : (rail.foldedWidth - digit.implicitWidth) / 2 }
        spacing: 10
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
          width: Math.max(0, Math.min(implicitWidth, tab.width - 12 - digit.width - parent.spacing - 8))
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
