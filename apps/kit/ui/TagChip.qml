import QtQuick

// TagChip is a tag's chip in a filter, `#tag`: a click picks it; a right
// click or the menu key opens the menu of its `actions` ({id, icon, text,
// guarded}), when it has any, `chosen` naming the one picked.
Chip {
  id: chip

  property string tag
  property var actions: []
  signal chosen(string id)

  text: "#" + chip.tag

  Keys.onPressed: event => {
    if (event.key !== Qt.Key_Menu || chip.actions.length === 0)
      return
    menu.open()
    event.accepted = true
  }

  MouseArea {
    anchors.fill: parent
    enabled: chip.actions.length > 0
    acceptedButtons: Qt.RightButton
    onClicked: menu.open()
  }

  MenuPopup {
    id: menu
    entries: chip.actions
    onPicked: index => chip.chosen(chip.actions[index].id)
  }
}
