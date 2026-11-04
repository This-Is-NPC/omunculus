pragma ComponentBehavior: Bound
import QtQuick

// CommandRow is a bar's actions, ranked, in the order given: the main one
// (`role: "primary"`) solid, the others outlined, those of one `group` joined
// as one control whose `checked` one is lit. Each shows its name while the
// names fit in `room`; when they do not, each shows its short name, or, with
// `iconsWhenTight`, every action but the main one shows only its icon, its
// name in the tip. With `overflows`, the actions that do not fit even by
// their short names leave the row, the lowest ranked first, a group as one,
// for `overflow`, whose holder takes `reserve` of the room; with `onlyMain`
// every action but the main one leaves. The main action never leaves.
Item {
  id: row

  // [{text, short, icon, tip, role, tone, group, checked, enabled, run}];
  // role is "primary", "guarded" or left out.
  property var commands: []
  // How wide the row may be.
  property real room: Infinity
  property bool iconsWhenTight: false
  property bool overflows: false
  property bool onlyMain: false
  // The room taken from the row by what holds `overflow`, once it holds any.
  property real reserve: 0
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
  readonly property bool tight: fullWidth > room

  // Each action's width with its name and with its short name, as measured.
  property var widths: []
  readonly property bool measured: widths.length === commands.length
  // The whole row's width with every name, and with every short name.
  readonly property real fullWidth: widthOf(runs, "full")
  readonly property real shortWidth: widthOf(runs, "brief")

  // What the row shows: its runs, by name or short name, and what left it.
  readonly property var plan: {
    if (!overflows || !measured)
      return { runs: runs, names: tight ? "brief" : "full", overflow: [] }
    if (onlyMain) {
      const kept = runs.filter(isMain)
      return { runs: kept, names: "brief", overflow: flatten(runs.filter(run => !isMain(run))) }
    }
    if (!tight)
      return { runs: runs, names: "full", overflow: [] }
    if (shortWidth <= room)
      return { runs: runs, names: "brief", overflow: [] }
    const kept = runs.slice()
    const left = []
    let at = kept.length - 1
    while (at >= 0 && widthOf(kept, "brief") + spacing + reserve > room) {
      if (!isMain(kept[at]))
        left.unshift(kept.splice(at, 1)[0])
      at--
    }
    return { runs: kept, names: "brief", overflow: flatten(left) }
  }
  // The actions that left the row, in their order.
  readonly property var overflow: plan.overflow

  implicitWidth: shown.implicitWidth
  implicitHeight: shown.implicitHeight

  function flatten(runs) { return runs.reduce((all, run) => all.concat(run), []) }
  function isMain(run) { return run.length === 1 && !run[0].group && run[0].role === "primary" }

  // How wide `runs` lie in a row, each action by its name ("full") or its
  // short name ("brief"); a group's actions share their edges.
  function widthOf(runs, names) {
    if (!measured)
      return 0
    let total = 0
    for (const run of runs) {
      for (const command of run)
        total += widths[commands.indexOf(command)][names]
      total -= run.length - 1
    }
    return total + Math.max(0, runs.length - 1) * spacing
  }

  function remeasure() { Qt.callLater(collect) }
  function collect() {
    const next = []
    for (let at = 0; at < measures.count; at++) {
      const item = measures.itemAt(at)
      next.push(item ? { full: item.full, brief: item.brief } : { full: 0, brief: 0 })
    }
    widths = next
  }

  // The actions with their names and with their short names, never drawn, to
  // know how wide they are.
  Column {
    // Hidden by opacity: a row that is not visible lays out nothing to measure.
    opacity: 0
    enabled: false
    Repeater {
      id: measures
      model: row.commands
      onCountChanged: row.remeasure()
      delegate: Item {
        id: measure
        required property var modelData
        readonly property real full: named.implicitWidth
        readonly property real brief: shortened.implicitWidth
        onFullChanged: row.remeasure()
        onBriefChanged: row.remeasure()
        Component.onCompleted: row.remeasure()
        TraceButton {
          id: named
          dense: true
          icon: measure.modelData.icon || ""
          text: measure.modelData.text
        }
        TraceButton {
          id: shortened
          dense: true
          icon: measure.modelData.icon || ""
          text: measure.modelData.short || measure.modelData.text
        }
      }
    }
  }

  Row {
    id: shown
    spacing: row.spacing

    Repeater {
      model: row.plan.runs
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
            text: iconOnly ? "" : row.plan.names === "brief" ? modelData.short || modelData.text : modelData.text
            maximumWidth: row.room - (row.overflow.length > 0 ? row.reserve : 0)
            width: iconOnly ? 32 : Math.min(implicitWidth, maximumWidth)
            tip: modelData.tip || (iconOnly ? modelData.text.toLowerCase() : "")
            enabled: modelData.enabled !== false
            onClicked: modelData.run()
          }
        }
      }
    }
  }
}
