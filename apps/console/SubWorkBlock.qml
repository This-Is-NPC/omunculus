pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// SubWorkBlock is a work handed down, in the thread of the run that handed it
// down, where it did: a frame headed SUB-WORK with its agent and title, one
// line with its state, how long and how many tool calls, its stages when it
// has a workflow, and the round with who sent it back when it was. Choosing
// it unfolds it in place, indented, into tabs: TRANSCRIPT, the work's own
// thread at most 480 px tall with its own scroll, CHANGES and RUNS. A block
// two levels down only opens; OPEN shows the work as a transcript of its own.
SurfaceFrame {
  id: block

  // The work handed down.
  required property string work
  // How deep the thread holding the block is nested: 0 for a page's own.
  property int nesting: 0
  property string stamp: ""
  property bool expanded: false
  property string tab: "transcript"
  // The work is wanted as a transcript of its own.
  signal opened(string work)

  readonly property var record: Omunculus.work(work)
  readonly property var progress: Omunculus.progress
  readonly property var node: progress ? progress.flat.find(item => item.work === work) || null : null
  readonly property string agent: node ? node.agent : record ? Omunculus.agentOf(record) : ""
  readonly property string title: node ? node.title : record ? record.title : ""
  readonly property string condition: node ? node.state : record ? record.state : ""
  readonly property bool expandable: nesting < 2
  readonly property real now: Omunculus.tick
  readonly property color stateTone: ({
    working: Theme.primary, "needs-you": Theme.warning, stopped: Theme.warning,
    failed: Theme.error, done: Theme.success
  })[condition] || Theme.dim
  readonly property string glyph: ({
    working: "●", "needs-you": "?", waiting: "○", stopped: "■", failed: "✕", done: "✓", cancelled: "–"
  })[condition] || "○"

  // The status line and the stages, in characters of their font; the status
  // keeps room for its separators.
  readonly property int budget: Math.max(8, Math.floor((width - 28) / metrics.advanceWidth("M")) - 1)
  readonly property var status: Progress.fit([
    { text: glyph + " " + (node ? node.word : condition.charAt(0).toUpperCase() + condition.slice(1)), keep: true },
    node && condition === "working" ? { text: Progress.clock(Math.max(0, now - node.since)), keep: true }
      : node && typeof node.finishedIn === "number" ? { text: "in " + Progress.span(node.finishedIn) }
      : null,
    node ? { text: node.calls === 1 ? "1 tool call" : node.calls + " tool calls", short: node.calls + " calls" } : null,
    node && node.failed > 0 ? { text: node.failed + " failed", keep: true } : null
  ].filter(part => part !== null), budget - 15).filter(text => text !== "")
  readonly property var stepper: node && node.steps.length > 0 ? Progress.stepper(node.steps, node.round, budget) : null

  readonly property bool showsTranscript: expanded && tab === "transcript"
  onShowsTranscriptChanged: {
    if (showsTranscript)
      transcript.setSource(Qt.resolvedUrl("TimelineView.qml"), { thread: block.work, nesting: block.nesting + 1, emptyText: "NOTHING SAID HERE YET" })
    else
      transcript.source = ""
  }

  function choose() {
    if (expandable)
      expanded = !expanded
    else
      opened(work)
  }

  implicitHeight: content.implicitHeight + 16
  variant: "outline"
  tone: stateTone
  active: condition === "needs-you"

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: 11 }

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8; leftMargin: 12; rightMargin: 12 }
    spacing: 4

    Item {
      id: head
      Layout.fillWidth: true
      implicitHeight: heading.implicitHeight + lines.implicitHeight + 4
      activeFocusOnTab: true
      Accessible.role: Accessible.Button
      Accessible.name: "sub-work " + block.title
      Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
          block.choose()
          event.accepted = true
        }
      }

      RowLayout {
        id: heading
        width: parent.width
        spacing: 6
        Icon { visible: block.expandable; name: block.expanded ? "chevron-down" : "chevron-right"; size: 10; color: pointer.containsMouse ? Theme.foreground : Theme.dim }
        Label { text: "SUB-WORK"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 1.5 }
        Label {
          Layout.minimumWidth: 0
          Layout.maximumWidth: implicitWidth
          Layout.fillWidth: true
          text: block.agent
          color: Omunculus.toneOf(block.agent)
          font.pixelSize: 11
          font.bold: true
          elide: Text.ElideRight
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: block.title
          color: Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Label { visible: block.stamp !== ""; text: block.stamp; color: Theme.dim; font.pixelSize: 11 }
      }

      Column {
        id: lines
        y: heading.height + 4
        width: parent.width
        spacing: 2

        Row {
          spacing: 0
          Repeater {
            model: block.status
            delegate: Label {
              required property string modelData
              required property int index
              text: (index > 0 ? "  ·  " : "") + modelData
              color: index === 0 ? block.stateTone : modelData.endsWith(" failed") ? Theme.error : Theme.dim
              font.pixelSize: 11
            }
          }
        }

        Row {
          visible: block.stepper !== null
          spacing: 0
          Repeater {
            model: block.stepper ? block.stepper.tokens : []
            delegate: Label {
              required property var modelData
              text: modelData.text
              color: modelData.status === "current" ? Theme.primary : modelData.status === "done" ? Theme.success : Theme.dim
              font.pixelSize: 11
              font.bold: modelData.status === "current"
            }
          }
        }

        Label {
          visible: !!block.node && block.node.round > 0
          width: parent.width
          text: block.node && block.node.sentBack
            ? "↩ Round " + block.node.round + " · sent back by " + block.node.sentBack.by + (block.node.sentBack.why ? ": \"" + block.node.sentBack.why + "\"" : "")
            : block.node ? "↩ Round " + block.node.round : ""
          color: Theme.warning
          font.pixelSize: 11
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: block.choose()
      }
      FocusRing { anchors.margins: -4 }
    }

    // Unfolded: the tabs, OPEN, and what the tab shows, indented.
    Flow {
      Layout.fillWidth: true
      visible: block.expanded
      spacing: 6
      Repeater {
        model: [{ name: "transcript", text: "TRANSCRIPT" }, { name: "changes", text: "CHANGES" }, { name: "runs", text: "RUNS" }]
        delegate: Chip {
          required property var modelData
          text: modelData.text
          checked: block.tab === modelData.name
          onClicked: block.tab = modelData.name
        }
      }
      TraceButton {
        dense: true
        role: "progress"
        icon: "chevron-right"
        text: "OPEN"
        tip: "show this work as a transcript of its own"
        onClicked: block.opened(block.work)
      }
    }

    TraceButton {
      visible: !block.expandable
      dense: true
      role: "progress"
      icon: "chevron-right"
      text: "OPEN"
      tip: "show this work as a transcript of its own"
      onClicked: block.opened(block.work)
    }

    Loader {
      id: transcript
      Layout.fillWidth: true
      Layout.leftMargin: 16
      Layout.preferredHeight: Math.min(480, implicitHeight)
      visible: block.showsTranscript
    }
    Connections {
      target: transcript.item
      ignoreUnknownSignals: true
      function onOpenWork(work) { block.opened(work) }
    }

    Loader {
      Layout.fillWidth: true
      Layout.leftMargin: 16
      Layout.preferredHeight: active ? 320 : 0
      active: block.expanded && block.tab === "changes"
      visible: active
      sourceComponent: WorkChanges { key: block.work }
    }

    Loader {
      Layout.fillWidth: true
      Layout.leftMargin: 16
      Layout.preferredHeight: active ? 320 : 0
      active: block.expanded && block.tab === "runs"
      visible: active
      sourceComponent: WorkRuns { key: block.work }
    }
  }
}
