pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// PageBar is the command bar beside a TabRail's head, which names the page:
// the commands of the page on screen, which slide in when the page changes,
// ranked, and at its end the app's readout. BACK stands first, apart; then
// the page's main action, solid; then the others, outlined, those of one
// `group` joined as one control whose `checked` one is lit; then, at the end,
// its tools (`place: "end"`), each only an icon with its name in the tip.
// When the names do not fit, each shows its short name.
Rectangle {
  id: bar

  // [{text, short, icon, tip, role, tone, group, checked, place, enabled,
  // run, shown}], in order; role is "back", "primary", "guarded" or left out.
  property var commands: []
  // Changes when the page does, so the commands arrive again.
  property int section: 0
  // The readout: the app's last message, whether it is an error, whether the
  // server is unreachable, and how many messages it has given.
  property string message: ""
  property bool error: false
  property bool offline: false
  property int notices: 0

  readonly property var shown: commands.filter(command => command.shown !== false)
  readonly property var back: shown.find(command => command.role === "back") || null
  readonly property var tools: shown.filter(command => command.place === "end")
  // The page's actions, each run of one group together: [[command]].
  readonly property var actions: shown.filter(command => command.role !== "back" && command.place !== "end")
    .reduce((runs, command) => {
      const last = runs.length > 0 ? runs[runs.length - 1] : null
      if (last && command.group && last[0].group === command.group)
        last.push(command)
      else
        runs.push([command])
      return runs
    }, [])
  // Whether the names fit beside the readout's room.
  readonly property bool compact: measure.implicitWidth > width - 340

  color: Qt.alpha(Theme.background, 0.9)
  border.color: Theme.line
  clip: true

  // The actions with their names, never drawn, to know how wide they are.
  Row {
    id: measure
    // Hidden by opacity: a row that is not visible lays out nothing to measure.
    opacity: 0
    enabled: false
    spacing: 10
    Repeater {
      model: [].concat(...bar.actions)
      delegate: TraceButton {
        required property var modelData
        dense: true
        icon: modelData.icon || ""
        text: modelData.text
      }
    }
  }

  onSectionChanged: arrive.restart()

  RowLayout {
    anchors { fill: parent; leftMargin: 8; rightMargin: 12 }
    spacing: 10

    TraceButton {
      Layout.alignment: Qt.AlignVCenter
      visible: bar.back !== null
      dense: true
      role: "navigation"
      icon: "chevron-left"
      text: bar.back ? bar.back.text : ""
      tip: bar.back ? bar.back.tip || "" : ""
      tone: Theme.dim
      onClicked: bar.back.run()
    }
    Rectangle {
      visible: bar.back !== null && bar.actions.length > 0
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: 1
      implicitHeight: 20
      color: Theme.line
    }

    Row {
      id: contextual
      Layout.alignment: Qt.AlignVCenter
      spacing: 10
      transform: Translate { id: shift }

      Repeater {
        model: bar.actions
        // A run of commands: one alone, or a group joined edge to edge.
        delegate: Row {
          id: run
          required property var modelData
          spacing: run.modelData.length > 1 ? -1 : 0
          Repeater {
            model: run.modelData
            delegate: TraceButton {
              required property var modelData
              dense: true
              role: modelData.group ? (modelData.checked ? "primary" : "action")
                : modelData.role === "primary" || modelData.role === "guarded" ? modelData.role : "action"
              filled: !modelData.group && modelData.role === "primary"
              tone: modelData.tone || (role === "guarded" ? Theme.error : modelData.group && !modelData.checked ? Theme.dim : Theme.primary)
              icon: modelData.icon || ""
              text: bar.compact ? modelData.short || modelData.text : modelData.text
              tip: modelData.tip || ""
              enabled: modelData.enabled !== false
              onClicked: modelData.run()
            }
          }
        }
      }
    }

    ParallelAnimation {
      id: arrive
      NumberAnimation { target: contextual; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
      NumberAnimation { target: shift; property: "x"; from: 16; to: 0; duration: 260; easing.type: Easing.OutCubic }
    }

    Item { Layout.fillWidth: true }

    StatusLine {
      Layout.alignment: Qt.AlignVCenter
      message: bar.message
      error: bar.error
      offline: bar.offline
      count: bar.notices
      maxWidth: Math.max(0, bar.width - contextual.width - toolRow.width - 140)
    }

    Row {
      id: toolRow
      Layout.alignment: Qt.AlignVCenter
      spacing: 6
      Repeater {
        model: bar.tools
        delegate: IconButton {
          required property var modelData
          name: modelData.icon || "more"
          tip: modelData.tip || modelData.text
          tone: modelData.tone || Theme.primary
          enabled: modelData.enabled !== false
          opacity: enabled ? 1 : 0.35
          onClicked: modelData.run()
        }
      }
    }
  }
}
