import QtQuick
import "kit/ui"

// AlwaysMenu is the "Always…" button of a permission: a menu of the wider
// scopes a grant is saved for in the project settings, one pick saving it.
// `options` are the scopes and `labels` how each reads.
Item {
  id: always

  property var options: []
  property var labels: []
  signal chosen(string option)

  implicitWidth: button.width
  implicitHeight: button.height
  width: button.width
  height: button.height
  visible: options.length > 0

  TraceButton {
    id: button
    dense: true
    maximumWidth: Infinity
    role: "action"
    icon: menu.opened ? "chevron-up" : "chevron-down"
    text: "ALWAYS…"
    tip: "grant it for a wider scope, saved in the project settings"
    onClicked: menu.opened ? menu.close() : menu.open()
  }

  MenuPopup {
    id: menu
    entries: [{ heading: "SAVED IN THE PROJECT SETTINGS" }].concat(always.labels.map(text => ({ text: text })))
    onPicked: index => always.chosen(always.options[index - 1])
  }
}
