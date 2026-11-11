pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Calls.js" as Calls
import "kit/client/Phrases.js" as Phrases
import "kit/client/Progress.js" as Progress
import "kit/ui"

// ToolCalls is what one run called, as a group under its words: system rows,
// the log and not a message, dim and small, the step mark in the rows' mark
// column. Folded, one line counts the calls, how many failed and the first
// that did; while the run is open its last three calls show live below it. A
// run that said nothing names its agent at the line's start, and how long it
// worked and when at its end, in place of a turn's heading.
// Unfolded, one row per call: the raw tool name, its args in brief, and under
// a failed call its output, six lines and then all on demand. An ask or an
// escalate names whom it goes to, never its question: the request's card or
// exchange shows that once. An edit opens a
// small diff of what it replaced, a write the first lines it wrote. Outcomes
// (moved on, sent back, stopped, granted) are rows in plain words, and the
// hooks that ran without trouble are one row.
Column {
  id: group

  // The run's steps, each {name, ok, text, args, output, outcome, hook?}.
  required property var steps
  // Whether the run is still open.
  property bool live: false
  // For a run that said nothing: its agent, how long it worked, and when.
  property string who: ""
  property string worked: ""
  property string stamp: ""
  property bool open: false

  readonly property var summary: Calls.group(steps.map(step => ["ask", "escalate"].includes(step.name) && !step.outcome
    ? Object.assign({}, step, { args: { to: step.args && typeof step.args.to === "string" ? step.args.to : "" } }) : step))
  readonly property int count: summary.calls
  readonly property var failedRow: summary.rows.find(row => !row.outcome && !row.ok) || null
  readonly property var rows: summary.rows
  // Unfolded, every row; folded and live, the last three.
  readonly property var shown: open ? rows : live ? rows.slice(-3) : []

  // The header in characters of its font, so it never runs past the width,
  // with room for the separators between its parts.
  readonly property int budget: Math.max(8, Math.floor((width - Theme.size.mark - stampWidth.advanceWidth - Theme.size.gutter) / (metrics.advanceWidth / metrics.text.length)) - 1)
  // A lone call that went well is named by what it did, not counted.
  readonly property var lone: count === 1 && summary.failed === 0 ? steps.find(step => !step.outcome && !step.hook) || null : null
  // A lone reply is named by whom it answers; the person's answers passed on
  // to a teammate say so.
  readonly property var answered: lone && lone.name === "reply" ? Omunculus.requests.find(request => request.id === (lone.args || {}).request_id) || null : null
  readonly property string loneText: !lone ? ""
    : answered ? Phrases.replied(answered.requester && answered.requester.agent || "", Progress.given(Omunculus.requests, answered, Omunculus.noted, Omunculus.me))
    : Phrases.did(lone.name, lone.args)
  readonly property string failedPrefix: summary.failed + " failed"
  readonly property var header: Progress.fit([
    who !== "" ? { text: who, keep: true, agent: true } : null,
    count > 0 ? { text: lone ? loneText : count === 1 ? "1 step" : count + " steps", short: lone ? loneText : count + " steps", keep: true } : null,
    summary.failed > 0 ? { text: failedPrefix + ": " + (failedRow ? Phrases.stepFailure(failedRow.name, failedRow.args) : ""), short: failedPrefix, keep: true } : null,
    worked !== "" ? { text: worked } : null
  ].filter(part => part !== null), budget - 6)

  visible: count > 0 || summary.failed > 0
  spacing: Theme.space.line

  TextMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: Theme.type.log.size; text: "MMMMMMMMMM" }
  TextMetrics { id: stampWidth; font.family: Theme.fontFamily; font.pixelSize: Theme.type.stamp.size; text: group.stamp }

  Item {
    id: head
    width: group.width
    height: Theme.size.stackedLine
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: group.header.filter(text => text !== "").join(" · ")
    Keys.onPressed: event => {
      if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
        group.open = !group.open
        event.accepted = true
      }
    }

    Icon {
      anchors.verticalCenter: parent.verticalCenter
      name: group.summary.failed > 0 ? "warning" : "step"
      size: Theme.type.log.size
      color: group.summary.failed > 0 ? Theme.error : Theme.dim
    }
    Row {
      id: line
      x: Theme.size.mark
      anchors.verticalCenter: parent.verticalCenter
      spacing: Theme.space.tight
      Repeater {
        // The agent leads with no separator after it.
        model: group.header
        delegate: Label {
          required property string modelData
          required property int index
          readonly property bool agent: group.who !== "" && index === 0
          visible: modelData !== ""
          // A delegate torn down has no parent.
          anchors.verticalCenter: parent ? parent.verticalCenter : undefined
          text: (index > (group.who !== "" ? 1 : 0) ? "· " : "") + modelData
          color: agent ? Omunculus.toneOf(group.who)
            : modelData.startsWith(group.failedPrefix) && group.summary.failed > 0 ? Theme.error
            : pointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: Theme.type.log.size
        }
      }
      Icon { anchors.verticalCenter: parent.verticalCenter; name: group.open ? "chevron-down" : "chevron-right"; size: Theme.type.log.size - 1; color: pointer.containsMouse ? Theme.foreground : Theme.dim }
    }
    Label {
      visible: group.stamp !== ""
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      text: group.stamp
      color: Theme.faint
      font.pixelSize: Theme.type.stamp.size
      font.letterSpacing: Theme.type.stamp.tracking
    }
    MouseArea {
      id: pointer
      width: line.x + line.width
      height: parent.height
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
      readonly property var diff: modelData.diff
      readonly property bool failed: !modelData.outcome && !modelData.ok
      property bool diffOpen: false
      property bool outputAll: false
      x: Theme.size.mark
      width: group.width - x
      spacing: Theme.space.row

      RowLayout {
        width: parent.width
        spacing: Theme.space.tight
        Label {
          Layout.alignment: Qt.AlignTop
          text: call.modelData.outcome ? ({ continue: "→", reopen: "↩", break: "✕" })[call.modelData.name] || "✓" : call.failed ? "✕" : "✓"
          color: call.failed ? Theme.error : call.modelData.name === "break" ? Theme.warning : call.modelData.outcome ? Theme.primary : Theme.success
          font.pixelSize: Theme.type.log.size
        }
        Label {
          visible: !call.modelData.outcome && !(call.modelData.hook && call.modelData.ok)
          Layout.maximumWidth: call.width * 0.4
          text: call.modelData.name
          color: call.failed ? Theme.error : Theme.foreground
          font.pixelSize: Theme.type.log.size
          elide: Text.ElideRight
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: call.modelData.brief
          color: call.modelData.outcome ? Theme.foreground : Theme.dim
          font.pixelSize: Theme.type.log.size
          elide: Text.ElideRight
        }
        // An edit's or write's size, which opens what it changed.
        Label {
          visible: call.diff !== null
          text: (call.diffOpen ? "▾ " : "▸ ") + (call.diff ? (call.diff.removed ? "diff +" + call.diff.added.length + " −" + call.diff.removed.length : "+" + call.diff.total + " lines") : "")
          color: diffPointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: Theme.type.log.size
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
        visible: call.failed && call.modelData.output !== ""
        x: Theme.space.section
        width: parent.width - x
        text: call.modelData.output
        color: Theme.error
        font.pixelSize: Theme.type.log.size
        wrapMode: Text.Wrap
        maximumLineCount: call.outputAll ? 100000 : 6
        elide: Text.ElideRight
      }
      Label {
        visible: output.visible && (output.truncated || call.outputAll)
        x: Theme.space.section
        text: call.outputAll ? "show less" : "show all"
        color: allPointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: Theme.type.log.size
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
        x: Theme.space.section
        width: parent.width - x
        height: visible ? lines.implicitHeight + Theme.space.cell : 0
        color: Theme.highlight
        border.color: Theme.line
        Column {
          id: lines
          x: Theme.space.tight
          y: Theme.space.tight
          width: parent.width - 2 * Theme.space.tight
          Repeater {
            model: call.diffOpen && call.diff ? (call.diff.removed || []).map(text => ({ text: text, added: false }))
              .concat(call.diff.added.map(text => ({ text: text, added: true }))) : []
            delegate: Label {
              required property var modelData
              width: lines.width
              text: (modelData.added ? "+ " : "− ") + modelData.text
              color: modelData.added ? Theme.success : Theme.error
              font.pixelSize: Theme.type.log.size
              elide: Text.ElideRight
            }
          }
          Label {
            visible: !!call.diff && call.diff.total !== undefined && call.diff.total > call.diff.added.length
            width: lines.width
            text: call.diff ? "… " + (call.diff.total - call.diff.added.length) + " more lines" : ""
            color: Theme.dim
            font.pixelSize: Theme.type.log.size
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
