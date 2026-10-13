pragma ComponentBehavior: Bound
import QtQuick

// CommandRow is a bar's actions, ranked, in the order given: the main one
// (`role: "primary"`) solid, the others outlined, those of one `group` joined
// as one control whose `checked` one is lit. Each shows its name while the
// names fit in `room`; when they do not, each shows its short name, or, with
// `iconsWhenTight`, every action but the main one shows only its icon, its
// name in the tip.
Item {
  id: row

  // [{text, short, icon, tip, role, tone, group, checked, enabled, run}];
  // role is "primary", "guarded" or left out.
  property var commands: []
  // How wide the row may be with every name shown.
  property real room: Infinity
  property bool iconsWhenTight: false
  property real spacing: 10

  // The actions, each run of one group together: [[command]].
  readonly property var runs: commands.reduce((runs, command) => {
      const last = runs.length > 0 ? runs[runs.length - 1] : null
      if (last && command.group && last[0].group === command.group)
        last.push(command)
      else
        runs.push([command])
      return runs
    }, [])
  readonly property bool tight: measure.implicitWidth > room

  implicitWidth: shown.implicitWidth
  implicitHeight: shown.implicitHeight

  // The actions with their names, never drawn, to know how wide they are.
  Row {
    id: measure
    // Hidden by opacity: a row that is not visible lays out nothing to measure.
    opacity: 0
    enabled: false
    spacing: row.spacing
    Repeater {
      model: row.commands
      delegate: TraceButton {
        required property var modelData
        dense: true
        icon: modelData.icon || ""
        text: modelData.text
      }
    }
  }

  Row {
    id: shown
    spacing: row.spacing

    Repeater {
      model: row.runs
      // A run of commands: one alone, or a group joined edge to edge.
      delegate: Row {
        id: run
        required property var modelData
        spacing: run.modelData.length > 1 ? -1 : 0
        Repeater {
          model: run.modelData
          delegate: TraceButton {
            required property var modelData
            readonly property bool main: !modelData.group && modelData.role === "primary"
            readonly property bool iconOnly: row.tight && row.iconsWhenTight && !main && !!modelData.icon
            dense: true
            role: modelData.group ? (modelData.checked ? "primary" : "action")
              : modelData.role === "primary" || modelData.role === "guarded" ? modelData.role : "action"
            filled: main
            tone: modelData.tone || (role === "guarded" ? Theme.error : modelData.group && !modelData.checked ? Theme.dim : Theme.primary)
            icon: modelData.icon || ""
            text: iconOnly ? "" : row.tight ? modelData.short || modelData.text : modelData.text
            width: iconOnly ? 32 : implicitWidth
            tip: modelData.tip || (iconOnly ? modelData.text.toLowerCase() : "")
            enabled: modelData.enabled !== false
            onClicked: modelData.run()
          }
        }
      }
    }
  }
}
