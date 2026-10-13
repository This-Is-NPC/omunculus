pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// CeilingFields edits the ceiling of one layer — an agent, a workspace, the
// policy: its mode and the names it has, may ask for, asks you for and never
// has. `changed` carries the whole layer, its other keys as they were; a list
// left empty, or the mode unset, leaves the layer.
ColumnLayout {
  id: fields

  required property var table
  property var choices: []
  signal changed(var table)

  // A layer names what it has in `granted` or, as the presets do, in `tools`.
  readonly property string has: table.granted !== undefined ? "granted" : "tools"

  function put(key, value) {
    const next = Object.assign({}, fields.table)
    if (value === null || (Array.isArray(value) && value.length === 0))
      delete next[key]
    else
      next[key] = value
    fields.changed(next)
  }

  spacing: 12

  PickRow {
    text: "MODE"
    options: ["", "auto", "allowlist", "blocklist"]
    current: fields.table.mode || ""
    describe: mode => mode === "" ? "unset" : mode
    dim: current === ""
    onPicked: mode => fields.put("mode", mode === "" ? null : mode)
  }
  Repeater {
    model: [[fields.has, "has"], ["negotiable", "may ask the agent above for"], ["human", "asks you for"], ["deny", "never has"]]
    delegate: NameSet {
      required property var modelData
      Layout.fillWidth: true
      label: modelData[1]
      items: fields.table[modelData[0]] || []
      choices: fields.choices
      onChanged: items => fields.put(modelData[0], items)
    }
  }
}
