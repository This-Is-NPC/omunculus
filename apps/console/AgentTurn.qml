pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Phrases.js" as Phrases
import "kit/ui"

// AgentTurn is one run of an agent in the conversation, said like a line of
// chat: on the left, under the agent's portrait and name in its colour, its
// words drawn as they stream, and the files it attached.
// Below them, one dim line says what it did in plain phrases — "Read 6
// files", how many attempts did not work, the work it closed or the access it
// granted; clicking it lists the calls in place, with why a failed one
// failed. Until the agent says or
// does anything, that line is the loading trace and how long it has worked.
// A turn that continues the same agent's drops its name and time. Hovering
// the words shows the way to copy them, in a gutter they never take.
Item {
  id: turn

  required property string who
  required property string text
  required property string partial
  required property bool streaming
  required property string steps
  // The files the run attached, as JSON.
  required property string files
  required property real at
  required property string stamp
  property bool continued: false
  property bool callsOpen: false

  readonly property var lines: JSON.parse(steps)
  readonly property var calls: lines.filter(line => !line.outcome)
  readonly property var outcomes: lines.filter(line => line.outcome)
  readonly property var attached: JSON.parse(files)
  readonly property var summary: Phrases.summarize(calls)
  readonly property string did: [summary.text].concat(outcomes.map(outcome => outcome.text)).filter(part => part !== "").join("  ·  ")
  readonly property string said: text + (partial !== "" ? (text !== "" ? "\n\n" : "") + partial : "")
  readonly property color tone: Omunculus.toneOf(who)
  // A run that said and did nothing leaves no trace in the conversation.
  readonly property bool empty: !streaming && said === "" && lines.length === 0 && attached.length === 0
  property double now: Date.now()
  readonly property int worked: Math.max(0, Math.round(now / 1000 - at))
  // Room beside the words kept for the copy button.
  readonly property real gutter: copy.implicitWidth + 12
  // About 70 characters at most per line.
  readonly property real widest: Math.min(620, turn.width < 520 ? turn.width - gutter : Math.min(turn.width * 0.78, turn.width - gutter))
  readonly property real inset: 10

  visible: !empty
  implicitHeight: empty ? 0 : body.y + body.height + 2

  // The time worked is counted in seconds while nothing has been said.
  Timer { running: turn.streaming && turn.said === ""; interval: 1000; repeat: true; triggeredOnStart: true; onTriggered: turn.now = Date.now() }

  HoverHandler { id: hover }

  IconButton {
    id: copy
    visible: hover.hovered && !turn.streaming && turn.text !== ""
    x: body.x + words.width + 12
    y: body.y + words.y + Math.min(0, (words.height - height) / 2)
    name: "copy"
    tip: "copy what it said"
    onClicked: Omunculus.copy(turn.text)
  }

  Column {
    id: body
    y: turn.continued ? 2 : 14
    width: turn.widest
    spacing: 4

    Row {
      visible: !turn.continued
      spacing: 8
      Portrait { width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter; agent: turn.who; source: Omunculus.imageOf(turn.who); tone: Omunculus.toneOf(turn.who) }
      Label { text: turn.who.toUpperCase(); color: turn.tone; font.pixelSize: 11; font.letterSpacing: 2 }
      Label { text: turn.stamp; color: Theme.dim; font.pixelSize: 11 }
    }

    Rectangle {
      id: words
      visible: turn.said !== ""
      width: Math.min(turn.widest, line.implicitWidth + 2 * turn.inset)
      height: line.implicitHeight + 14
      color: Qt.tint(Theme.background, Qt.alpha(turn.tone, 0.1))
      Prose {
        id: line
        anchors.verticalCenter: parent.verticalCenter
        x: turn.inset
        width: Math.min(implicitWidth, turn.widest - 2 * turn.inset)
        // Drawn as it is while it streams, with its open marks closed, so the
        // words already read never move.
        source: Omunculus.inline(turn.streaming ? Omunculus.closed(turn.said) : turn.said)
        color: Theme.foreground
        font.pixelSize: 12
        lineHeight: 1.2
        wrapMode: Text.Wrap
      }
    }

    // The files it attached, each opening when chosen.
    Flow {
      visible: turn.attached.length > 0
      width: turn.widest
      spacing: 6
      Repeater {
        model: turn.attached
        delegate: FileChip {
          required property var modelData
          file: modelData
          onClicked: Omunculus.openAttachment(modelData)
        }
      }
    }

    // Working and nothing to show yet: the trace, and for how long.
    Row {
      visible: turn.streaming && turn.said === "" && turn.calls.length === 0
      spacing: 10
      LoadingTrace {
        anchors.verticalCenter: parent.verticalCenter
        width: 120
        height: 16
        running: parent.visible
        tone: turn.tone
      }
      Label { anchors.verticalCenter: parent.verticalCenter; text: "Working " + turn.worked + "s"; color: turn.tone; font.pixelSize: 11; font.letterSpacing: 1 }
    }

    // What it did, on one dim line; the calls open below it.
    Item {
      visible: turn.did !== "" || turn.summary.failed
      width: Math.min(turn.widest, did.implicitWidth + 18)
      height: did.implicitHeight + 4
      Row {
        id: did
        spacing: 6
        Icon { anchors.verticalCenter: parent.verticalCenter; name: turn.callsOpen ? "chevron-down" : "chevron-right"; size: 10; color: pointer.containsMouse ? turn.tone : Theme.dim }
        Label {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, turn.widest - 24)
          text: turn.did + (turn.streaming ? (turn.did !== "" ? "  ·  " : "") + "working " + turn.worked + "s" : "")
          color: pointer.containsMouse ? Theme.foreground : Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Icon { visible: turn.summary.failed; anchors.verticalCenter: parent.verticalCenter; name: "close"; size: 10; color: Theme.error }
        Label {
          visible: turn.summary.failed
          anchors.verticalCenter: parent.verticalCenter
          text: turn.summary.failedText
          color: Theme.error
          font.pixelSize: 11
        }
      }
      MouseArea {
        id: pointer
        anchors.fill: parent
        enabled: turn.calls.length > 0
        hoverEnabled: true
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: turn.callsOpen = !turn.callsOpen
      }
    }

    Column {
      visible: turn.callsOpen
      x: 16
      width: turn.widest - 16
      spacing: 6
      Repeater {
        model: turn.callsOpen ? turn.calls : []
        delegate: Column {
          id: call
          required property var modelData
          width: parent.width
          spacing: 2
          Row {
            spacing: 8
            Icon { anchors.verticalCenter: parent.verticalCenter; name: call.modelData.ok ? "check" : "close"; size: 10; color: call.modelData.ok ? Theme.success : Theme.error }
            Label { text: Phrases.phrase(call.modelData.name, call.modelData.args); color: Theme.foreground; font.pixelSize: 11 }
          }
          Label {
            visible: call.modelData.text !== ""
            x: 18
            width: parent.width - 18
            text: call.modelData.text
            color: Theme.dim
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          Label {
            visible: call.modelData.output !== ""
            x: 18
            width: parent.width - 18
            text: call.modelData.output
            color: Theme.error
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
}
