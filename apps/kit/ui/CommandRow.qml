pragma ComponentBehavior: Bound
import QtQuick

// CommandRow is a bar's actions, ranked: the main one (`role: "primary"`)
// first and solid, then the others outlined, in the order given but the
// guarded ones last behind a hairline, those of one `group` joined as one
// control whose `checked` one is lit. Spread, the main one keeps the left edge
// and the others the right. Each shows its name while the names fit in `room`;
// when they do not, each shows its short name, or, with `iconsWhenTight` and
// the short names still too wide, every action but the main one shows only its
// icon, its name in the tip. With `overflows`, the actions that do not fit even
// so leave the row, the lowest ranked first, a group as one, for `overflow`,
// whose holder takes `reserve` of the room. The main action never leaves.
Item {
  id: row

  // [{text, short, icon, tip, role, tone, group, checked, enabled, run}];
  // role is "primary", "guarded" or left out.
  property var commands: []
  // How wide the row may be.
  property real room: Infinity
  property bool iconsWhenTight: false
  property bool overflows: false
  // The room taken from the row by what holds `overflow`, once it holds any.
  property real reserve: 0
  property real spacing: Theme.space.gap
  // The main action at the left edge, the others at the right.
  property bool spread: false

  function isMain(command) { return !command.group && command.role === "primary" }
  readonly property var leading: runs(commands.filter(command => isMain(command)))
  readonly property var plain: runs(commands.filter(command => !isMain(command) && command.role !== "guarded"))
  readonly property var guarded: runs(commands.filter(command => !isMain(command) && command.role === "guarded"))
  readonly property var ranked: leading.concat(plain, guarded)

  // Each action's width with its name and with its short name, as measured.
  property var widths: []
  readonly property bool measured: widths.length === commands.length
  readonly property bool tight: widthOf(ranked, "full") > room
  // Tight, but every action's short name fits.
  readonly property bool shortened: tight && widthOf(ranked, "brief") <= room
  // How the actions are shown: by name ("full"), by short name ("brief"), or
  // all but the main one as icons ("icon").
  readonly property string names: !tight ? "full" : shortened || !iconsWhenTight ? "brief" : "icon"

  // What the row shows, and what left it: the runs of the lowest rank leave
  // first while the rest is wider than the room.
  readonly property var plan: {
    const kept = ranked.slice()
    const left = []
    if (overflows && measured && tight && !shortened) {
      for (let at = kept.length - 1; at >= 0 && widthOf(kept, names) + spacing + reserve > room; at--) {
        if (!isMain(kept[at][0]))
          left.unshift(kept.splice(at, 1)[0])
      }
    }
    return { kept: kept, overflow: flatten(left) }
  }
  // The actions that left the row, in their rank.
  readonly property var overflow: plan.overflow
  readonly property var keptLeading: leading.filter(run => plan.kept.includes(run))
  readonly property var keptPlain: plain.filter(run => plan.kept.includes(run))
  readonly property var keptGuarded: guarded.filter(run => plan.kept.includes(run))
  // A hairline parts the guarded commands from the others before them.
  readonly property bool divided: keptPlain.length > 0 && keptGuarded.length > 0

  implicitWidth: lead.implicitWidth + trail.implicitWidth + (keptLeading.length > 0 && trail.implicitWidth > 0 ? spacing : 0)
  implicitHeight: Math.max(lead.implicitHeight, trail.implicitHeight)

  // Each run of one group together: [[command]].
  function runs(commands) {
    return commands.reduce((all, command) => {
      const last = all.length > 0 ? all[all.length - 1] : null
      if (last && command.group && last[0].group === command.group)
        last.push(command)
      else
        all.push([command])
      return all
    }, [])
  }
  function flatten(runs) { return runs.reduce((all, run) => all.concat(run), []) }
  function iconOnly(command) { return names === "icon" && !isMain(command) && !!command.icon }

  // How wide `runs` lie in a row, each action as `names` shows it; a group's
  // actions share their edges, and the guarded ones stand behind a hairline.
  function widthOf(runs, names) {
    if (!measured)
      return 0
    let total = 0
    for (const run of runs) {
      for (const command of run) {
        // A run of the commands before they changed counts nothing until it follows them.
        const width = widths[commands.indexOf(command)] || { full: 0, brief: 0 }
        total += names === "icon" && !isMain(command) && command.icon ? 32 : names === "full" ? width.full : width.brief
      }
      total -= run.length - 1
    }
    const parted = runs.some(run => plain.includes(run)) && runs.some(run => guarded.includes(run))
    return total + Math.max(0, runs.length - 1) * spacing + (parted ? 1 + spacing : 0)
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

  // A run of commands: one alone, or a group joined edge to edge.
  Component {
    id: runDelegate
    Row {
      id: run
      required property var modelData
      spacing: run.modelData.length > 1 ? -1 : 0
      Repeater {
        model: run.modelData
        delegate: TraceButton {
          required property var modelData
          readonly property bool iconOnly: row.iconOnly(modelData)
          dense: true
          role: modelData.group ? (modelData.checked ? "primary" : "action")
            : modelData.role === "primary" || modelData.role === "guarded" ? modelData.role : "action"
          filled: row.isMain(modelData)
          tone: modelData.tone || (role === "guarded" ? Theme.error : modelData.group && !modelData.checked ? Theme.dim : Theme.primary)
          icon: modelData.icon || ""
          text: iconOnly ? "" : row.names === "full" ? modelData.text : modelData.short || modelData.text
          maximumWidth: row.room - (row.overflow.length > 0 ? row.reserve : 0)
          width: iconOnly ? 32 : Math.min(implicitWidth, maximumWidth)
          tip: modelData.tip || (iconOnly ? modelData.text.toLowerCase() : "")
          enabled: modelData.enabled !== false
          onClicked: modelData.run()
        }
      }
    }
  }

  // The main action, then the others.
  Row {
    id: lead
    anchors.verticalCenter: parent.verticalCenter
    spacing: row.spacing
    Repeater { model: row.keptLeading; delegate: runDelegate }
  }
  Row {
    id: trail
    anchors.verticalCenter: parent.verticalCenter
    x: row.spread ? row.width - width : lead.width + (row.keptLeading.length > 0 ? row.spacing : 0)
    spacing: row.spacing
    Repeater { model: row.keptPlain; delegate: runDelegate }
    Rectangle {
      visible: row.divided
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: 20
      color: Theme.line
    }
    Repeater { model: row.keptGuarded; delegate: runDelegate }
  }
}
