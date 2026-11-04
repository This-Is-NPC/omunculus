pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// AgentTurn is one run of an agent in the conversation, said like a line of
// chat: on the left, under the agent's portrait, its name in its colour, the
// time and how long it has worked ("Working 0:12" while the run is open,
// "Worked 1 min" after), its words drawn as they stream, the files it
// attached, and the group of its tool calls (ToolCalls). Until the agent says
// or does anything the turn is not drawn. A turn that continues the same
// agent's drops its header. Hovering the words shows the way to copy them,
// in a gutter they never take.
Item {
  id: turn

  // The run.
  required property string run
  required property string who
  required property string text
  required property string partial
  required property bool streaming
  required property string steps
  // The files the run attached, as JSON.
  required property string files
  required property string stamp
  property bool continued: false

  readonly property var lines: JSON.parse(steps)
  readonly property var attached: JSON.parse(files)
  // When the run started and ended, in seconds; the end is 0 while it is open.
  readonly property real started: Omunculus.runStarts[run] || 0
  readonly property real ended: {
    const record = Omunculus.runs.find(item => item.id === run)
    return record && record.finished_at ? Date.parse(record.finished_at) / 1000 : 0
  }
  readonly property string worked: started <= 0 ? ""
    : streaming ? "Working " + Progress.clock(Math.max(0, Omunculus.tick - started))
    : ended > 0 ? "Worked " + Progress.span(Math.max(0, ended - started)) : ""
  readonly property string said: text + (partial !== "" ? (text !== "" ? "\n\n" : "") + partial : "")
  readonly property color tone: Omunculus.toneOf(who)
  // A run that has said and done nothing so far leaves no trace in the
  // conversation; the progress strip says that the team works.
  readonly property bool empty: said === "" && lines.length === 0 && attached.length === 0
  // Room beside the words kept for the copy button.
  readonly property real gutter: copy.implicitWidth + 12
  // About 70 characters at most per line.
  readonly property real widest: Math.min(620, turn.width < 520 ? turn.width - gutter : Math.min(turn.width * 0.78, turn.width - gutter))
  readonly property real inset: 10

  visible: !empty
  implicitHeight: empty ? 0 : body.y + body.height + 2

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

    RowLayout {
      visible: !turn.continued
      width: turn.widest
      spacing: 8
      Portrait { Layout.preferredWidth: 20; Layout.preferredHeight: 20; agent: turn.who; source: Omunculus.imageOf(turn.who); tone: Omunculus.toneOf(turn.who) }
      Label { Layout.minimumWidth: 0; Layout.maximumWidth: implicitWidth; Layout.fillWidth: true; text: turn.who.toUpperCase(); color: turn.tone; font.pixelSize: 11; font.letterSpacing: 2; font.bold: true; elide: Text.ElideRight }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: turn.stamp + (turn.worked !== "" ? "  ·  " + turn.worked : "")
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
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

    ToolCalls {
      width: turn.widest
      steps: turn.lines
      live: turn.streaming
    }
  }
}
