pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Calls.js" as Calls
import "kit/client/Progress.js" as Progress
import "kit/ui"

// ToolCalls is what one run called, as a group under its words. Folded, one
// line counts the calls, how many failed and the first that did, and how long
// they took; while the run is open its last three calls show live below it.
// Unfolded, one row per call: the raw tool name, its args in brief, and under
// a failed call its output, six lines and then all on demand. An edit opens a
// small diff of what it replaced, a write the first lines it wrote. Outcomes
// (moved on, sent back, stopped, granted) are rows in plain words, and the
// hooks that ran without trouble are one row.
Column {
  id: group

  // The run's steps, each {name, ok, text, args, output, outcome, hook?}.
  required property var steps
  // Whether the run is still open.
  property bool live: false
  property bool open: false

  readonly property var summary: Calls.group(steps)
  readonly property int count: summary.calls
  readonly property var failedRow: summary.rows.find(row => !row.outcome && !row.ok) || null
  readonly property var rows: summary.rows
  // Unfolded, every row; folded and live, the last three.
  readonly property var shown: open ? rows : live ? rows.slice(-3) : []

  // The header in characters of its font, so it never runs past the width,
  // with room for the separators between its parts.
  readonly property int budget: Math.max(8, Math.floor((width - 18) / metrics.advanceWidth("M")) - 1)
  readonly property string failedPrefix: summary.failed + " failed"
  readonly property var header: Progress.fit([
    { text: count === 1 ? "1 tool call" : count + " tool calls", short: count + " calls", keep: true },
    summary.failed > 0 ? { text: failedPrefix + ": " + (failedRow ? failedRow.name : ""), short: failedPrefix, keep: true } : null,
    summary.seconds !== undefined ? { text: Progress.span(summary.seconds) } : null
  ].filter(part => part !== null), budget - 6).filter(text => text !== "")

  visible: rows.length > 0
  spacing: 4

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: 11 }

  Item {
    id: head
    width: Math.min(group.width, line.implicitWidth + 4)
    height: 20
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: group.header.join(" · ")
    Keys.onPressed: event => {
      if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
        group.open = !group.open
        event.accepted = true
      }
    }

    Row {
      id: line
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6
      Icon { anchors.verticalCenter: parent.verticalCenter; name: group.open ? "chevron-down" : "chevron-right"; size: 10; color: pointer.containsMouse ? Theme.foreground : Theme.dim }
      Repeater {
        model: group.header
        delegate: Label {
          required property string modelData
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          text: (index > 0 ? "· " : "") + modelData
          color: modelData.startsWith(group.failedPrefix) && group.summary.failed > 0 ? Theme.error
            : pointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: 11
        }
      }
    }
    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: group.open = !group.open
    }
    FocusRing { anchors.margins: -2 }
  }

  Repeater {
    model: group.shown
    delegate: Column {
      id: call
      required property var modelData
      readonly property var diff: modelData.diff || null
      readonly property bool failed: !modelData.outcome && !modelData.ok
      property bool diffOpen: false
      property bool outputAll: false
      x: 16
      width: group.width - 16
      spacing: 2

      RowLayout {
        width: parent.width
        spacing: 8
        Label {
          Layout.alignment: Qt.AlignTop
          text: call.modelData.outcome ? ({ continue: "→", reopen: "↩", break: "✕" })[call.modelData.name] || "✓" : call.failed ? "✕" : "✓"
          color: call.failed ? Theme.error : call.modelData.name === "break" ? Theme.warning : call.modelData.outcome ? Theme.primary : Theme.success
          font.pixelSize: 11
        }
        Label {
          visible: !call.modelData.outcome && !(call.modelData.hook && call.modelData.ok)
          Layout.maximumWidth: call.width * 0.4
          text: call.modelData.name
          color: call.failed ? Theme.error : Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: call.modelData.outcome ? call.modelData.text || call.modelData.brief || "" : call.modelData.brief || ""
          color: call.modelData.outcome ? Theme.foreground : Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        // An edit's or write's size, which opens what it changed.
        Label {
          visible: call.diff !== null
          text: (call.diffOpen ? "▾ " : "▸ ") + (call.diff ? (call.diff.removed ? "diff +" + call.diff.added.length + " −" + call.diff.removed.length : "+" + call.diff.total + " lines") : "")
          color: diffPointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: 11
          MouseArea {
            id: diffPointer
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: call.diffOpen = !call.diffOpen
          }
        }
      }

      Label {
        id: output
        visible: call.failed && String(call.modelData.output || "") !== ""
        x: 18
        width: parent.width - 18
        text: String(call.modelData.output || "")
        color: Theme.error
        font.pixelSize: 11
        wrapMode: Text.Wrap
        maximumLineCount: call.outputAll ? 100000 : 6
        elide: Text.ElideRight
      }
      Label {
        visible: output.visible && (output.truncated || call.outputAll)
        x: 18
        text: call.outputAll ? "show less" : "show all"
        color: allPointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: 11
        font.underline: true
        MouseArea {
          id: allPointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: call.outputAll = !call.outputAll
        }
      }

      // What an edit removed and added, or the first lines a write wrote.
      Rectangle {
        visible: call.diffOpen && call.diff !== null
        x: 18
        width: parent.width - 18
        height: visible ? lines.implicitHeight + 12 : 0
        color: Theme.highlight
        border.color: Theme.line
        Column {
          id: lines
          x: 8
          y: 6
          width: parent.width - 16
          Repeater {
            model: call.diffOpen && call.diff ? (call.diff.removed || []).map(text => ({ text: text, added: false }))
              .concat((call.diff.added || []).map(text => ({ text: text, added: true }))) : []
            delegate: Label {
              required property var modelData
              width: lines.width
              text: (modelData.added ? "+ " : "− ") + modelData.text
              color: modelData.added ? Theme.success : Theme.error
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
          Label {
            visible: !!call.diff && call.diff.total !== undefined && call.diff.total > call.diff.added.length
            width: lines.width
            text: call.diff ? "… " + (call.diff.total - call.diff.added.length) + " more lines" : ""
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
