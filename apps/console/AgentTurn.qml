pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// AgentTurn is one run of an agent in the conversation, said like a line of
// chat: on the left, under a heading of the agent's tone dot, its name, the
// time and how long it has worked ("Working 0:12" while the run is open,
// "Worked 1 min" after), its words drawn as they stream in a box tinted with
// its colour, the files it attached, and the group of its tool calls
// (ToolCalls). Until the agent says or does anything the turn is not drawn.
// A turn that continues the same agent's drops its heading. Once it has
// said something, the "more" button beside the words, in a gutter they never
// take, copies them or shows the run's work in the log.
Item {
  id: turn

  // The run, and the work it ran on ("" for the conversation's own).
  required property string run
  property string work: ""
  required property string who
  required property string text
  required property string partial
  required property bool streaming
  required property string steps
  // The files the run attached, as JSON.
  required property string files
  required property string stamp
  property bool continued: false
  // The keyboard is on this turn: its menu is then a stop of Tab.
  property bool selected: false
  // The log of the run's work is wanted.
  signal logged(string work)

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
  // About 70 characters at most per line, the gutter kept for the menu.
  readonly property real widest: Math.min(620, turn.width < Theme.size.measureFrom ? turn.width - Theme.size.gutter : Math.min(turn.width * Theme.size.measure, turn.width - Theme.size.gutter))
  readonly property real inset: Theme.size.bubbleInset

  visible: !empty
  implicitHeight: empty ? 0 : body.y + body.height + Theme.space.row

  Column {
    id: body
    y: turn.continued ? Theme.space.row : Theme.space.inset
    width: turn.widest
    spacing: Theme.space.line

    RowLayout {
      visible: !turn.continued
      width: turn.widest
      spacing: Theme.space.tight
      Dot { Layout.alignment: Qt.AlignVCenter; tone: turn.tone }
      Label {
        Layout.minimumWidth: 0
        Layout.maximumWidth: implicitWidth
        Layout.fillWidth: true
        text: turn.who.toUpperCase()
        color: turn.tone
        font.pixelSize: Theme.type.name.size
        font.letterSpacing: Theme.type.name.tracking
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: (turn.stamp + (turn.worked !== "" ? Theme.type.meta.separator + turn.worked : "")).toUpperCase()
        color: Qt.alpha(turn.tone, Theme.type.stamp.opacity)
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
        elide: Text.ElideRight
      }
    }

    Rectangle {
      id: words
      visible: turn.said !== ""
      width: Math.min(turn.widest, line.implicitWidth + 2 * turn.inset)
      height: line.implicitHeight + Theme.space.inset
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
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
      }
    }

    // The files it attached, each opening when chosen.
    Flow {
      visible: turn.attached.length > 0
      width: turn.widest
      spacing: Theme.space.tight
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

  // The words' menu, always in sight once they are whole: beside the box's
  // first row, on the side that faces the rest of the thread.
  IconButton {
    id: more
    visible: words.visible && !turn.streaming && turn.text !== ""
    quiet: true
    activeFocusOnTab: turn.selected
    highlighted: activeFocus || menu.opened
    implicitWidth: Theme.size.gutter - Theme.space.line
    implicitHeight: Theme.size.gutter - Theme.space.line
    x: body.x + words.width + Theme.space.line
    // Centred on the box's first row, however many rows it has.
    y: body.y + words.y + Theme.space.inset / 2 + line.implicitHeight / Math.max(1, line.lineCount) / 2 - height / 2
    name: "more"
    tip: menu.opened ? "" : "copy what it said, or show its work in the log"
    onClicked: menu.opened ? menu.close() : menu.open()

    MenuPopup {
      id: menu
      entries: [{ icon: "copy", text: "COPY" }, { icon: "list", text: "SHOW IN LOG" }]
      onPicked: index => index === 0 ? Omunculus.copy(turn.text) : turn.logged(turn.work)
    }
  }
}
