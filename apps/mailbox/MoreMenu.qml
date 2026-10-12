pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as C
import "gui"

// MoreMenu is what a "more" button opens below itself, as eco's menus are: a
// hairline frame that fades and settles in, one row per entry ({text, icon,
// guarded}), aligned to the button's right edge. Up and Down move, Enter
// picks, Esc closes; `picked` gives the entry's index.
C.Popup {
  id: menu

  property var entries: []
  property int current: 0
  signal picked(int index)

  function pick(index) {
    close()
    picked(index)
  }

  focus: true
  FocusKeeper { popup: menu }
  y: parent.height + 4
  x: parent.width - width
  width: 220
  padding: 4
  margins: 8
  height: column.implicitHeight + 8
  onAboutToShow: current = 0
  background: Rectangle { color: Theme.background; border.color: Theme.line }
  enter: Transition {
    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 110 }
    NumberAnimation { property: "scale"; from: 0.97; to: 1; duration: 110; easing.type: Easing.OutCubic }
  }
  exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 90 } }

  contentItem: Column {
    id: column
    focus: true
    Keys.onPressed: event => {
      if (event.key === Qt.Key_Down)
        menu.current = Math.min(menu.entries.length - 1, menu.current + 1)
      else if (event.key === Qt.Key_Up)
        menu.current = Math.max(0, menu.current - 1)
      else if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key) && menu.entries.length > 0)
        menu.pick(menu.current)
      else
        return
      event.accepted = true
    }
    Repeater {
      model: menu.entries
      delegate: ChoiceRow {
        required property var modelData
        required property int index
        width: column.width
        text: modelData.text
        icon: modelData.icon || ""
        guarded: !!modelData.guarded
        current: index === menu.current
        onPicked: menu.pick(index)
      }
    }
  }
}
