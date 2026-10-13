pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// BodyFields edits a model's `body`, what goes over every request its adapter
// sends: one row per option, its key written with dots for nested tables
// ("reasoning.effort"), its value read as JSON when it is (a number, true, a
// list) and as text otherwise. The options an api is known to take are
// offered first; any other key is typed.
ColumnLayout {
  id: fields

  required property var table
  property string api: ""
  signal changed(var table)

  readonly property var known: ({
    "openai-completions": ["reasoning_effort", "max_completion_tokens", "top_p", "seed", "parallel_tool_calls", "reasoning.effort"],
    "openai-responses": ["reasoning.effort", "reasoning.summary", "max_output_tokens", "top_p", "parallel_tool_calls"],
    "anthropic-messages": ["max_tokens", "thinking.type", "thinking.budget_tokens", "top_p", "top_k"]
  })[api] || []

  // The table as [key with dots, value] rows, nested tables opened.
  readonly property var rows: {
    const rows = []
    const walk = (table, prefix) => {
      for (const key of Object.keys(table)) {
        const value = table[key]
        if (value !== null && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length > 0)
          walk(value, prefix + key + ".")
        else
          rows.push([prefix + key, value])
      }
    }
    walk(table || {}, "")
    return rows
  }

  function shown(value) { return typeof value === "string" ? value : JSON.stringify(value) }
  function read(text) {
    try {
      return JSON.parse(text)
    } catch (e) {
      return text
    }
  }

  // The table with the option at `dotted` set to `value`, or removed for undefined.
  function with_(dotted, value) {
    const next = JSON.parse(JSON.stringify(fields.table || {}))
    const keys = dotted.split(".")
    let table = next
    const trail = []
    for (const key of keys.slice(0, -1)) {
      if (typeof table[key] !== "object" || table[key] === null || Array.isArray(table[key]))
        table[key] = {}
      trail.push([table, key])
      table = table[key]
    }
    if (value === undefined)
      delete table[keys[keys.length - 1]]
    else
      table[keys[keys.length - 1]] = value
    // A table left empty leaves its parent.
    for (const [parent, key] of trail.reverse())
      if (Object.keys(parent[key]).length === 0)
        delete parent[key]
    return next
  }

  function add(dotted) {
    const key = dotted.trim()
    if (key !== "" && !fields.rows.some(row => row[0] === key))
      fields.changed(fields.with_(key, ""))
  }

  spacing: 6

  Caption { text: "OPTIONS  ·  SENT IN EVERY REQUEST" }
  Repeater {
    model: fields.rows.length
    delegate: RowLayout {
      id: row
      required property int index
      readonly property var entry: fields.rows[index] || ["", ""]
      Layout.fillWidth: true
      spacing: 6
      Label {
        Layout.preferredWidth: 220
        text: row.entry[0]
        color: Theme.foreground
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      SyncedBox {
        Layout.fillWidth: true
        dense: true
        value: fields.shown(row.entry[1])
        onTextEdited: fields.changed(fields.with_(row.entry[0], fields.read(text)))
      }
      IconButton {
        name: "close"
        tone: Theme.error
        tip: "take " + row.entry[0] + " out"
        onClicked: fields.changed(fields.with_(row.entry[0], undefined))
      }
    }
  }
  Flow {
    Layout.fillWidth: true
    spacing: 6
    Dropdown {
      visible: options.length > 0
      options: fields.known.filter(key => !fields.rows.some(row => row[0] === key))
      current: ""
      label: "ADD OPTION"
      onPicked: key => fields.add(key)
    }
    TextBox {
      width: 200
      dense: true
      placeholderText: "other option, a.b for a table"
      onAccepted: { fields.add(text); text = "" }
    }
  }
}
