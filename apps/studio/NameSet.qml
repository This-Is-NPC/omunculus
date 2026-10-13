pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// NameSet edits a list of names a ceiling holds: each name a chip that leaves
// the list when pressed, a list of the `choices` it does not hold yet, and,
// unless the choices are all there is (`closed`), a field for a name they
// lack, as an MCP server's tool.
ColumnLayout {
  id: set

  required property var items
  property string label
  property var choices: []
  property bool closed: false
  signal changed(var items)

  function add(name) {
    const value = name.trim()
    if (value !== "" && !set.items.includes(value))
      set.changed([...set.items, value])
  }

  spacing: 6

  Caption { visible: set.label !== ""; text: set.label.toUpperCase() }
  Flow {
    Layout.fillWidth: true
    spacing: 6
    Repeater {
      model: set.items
      delegate: Chip {
        required property string modelData
        text: modelData
        icon: "close"
        tip: "take " + modelData + " out"
        onClicked: set.changed(set.items.filter(item => item !== modelData))
      }
    }
    Dropdown {
      visible: options.length > 0
      options: set.choices.filter(choice => !set.items.includes(choice))
      current: ""
      label: "ADD"
      onPicked: choice => set.add(choice)
    }
    TextBox {
      visible: !set.closed
      width: 150
      dense: true
      placeholderText: "other name"
      onAccepted: { set.add(text); text = "" }
    }
  }
}
