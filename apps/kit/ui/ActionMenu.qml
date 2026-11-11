import QtQuick
import "Breakpoints.js" as Breakpoints

// ActionMenu keeps a view's less frequent actions behind one "more" button,
// opening a list aligned to its right edge. `items` are {id, icon, text,
// guarded}; `chosen` names the one picked.
Item {
  id: menu

  property var items: []
  property string tip
  // The side of the button.
  property real control: Breakpoints.target(Window.width)
  signal chosen(string id)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IconButton {
    id: button
    name: "more"
    implicitWidth: menu.control
    tip: menu.tip
    highlighted: list.opened
    onClicked: list.opened ? list.close() : list.open()
  }

  MenuPopup {
    id: list
    alignRight: true
    entries: menu.items
    onPicked: index => menu.chosen(menu.items[index].id)
  }
}
