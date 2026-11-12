pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Phrases.js" as Phrases
import "kit/client/Progress.js" as Progress
import "kit/ui"

// SubWorkBlock is a work handed down, in the thread of the run that handed it
// down, where it did: a system row of the log, the branch mark in the rows'
// mark column, SUB-WORK with its agent and title, then under them one line
// with its state, how long and how many tool calls, its stages when it has a
// workflow, and the round with who sent it back when it was. Choosing it
// unfolds it in place, in a frame under the row, into tabs (01 TRANSCRIPT, the work's own
// thread at most 480 px tall with its own scroll, 02 CHANGES and 03 RUNS). A
// block two levels down only opens. The open tool at its top right shows the
// work as a transcript of its own. The conversation's own work leaves out its
// title, which the masthead shows; until the work's
// data arrives, the block shows the title and "Handing down…".
Item {
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
  // Until the work's data arrives, the title the event named.
  readonly property bool arrived: record !== null || node !== null
  readonly property string agent: node ? node.agent : record ? Omunculus.agentOf(record) : ""
  readonly property string title: node ? node.title : record ? record.title : Omunculus.titles[work] || ""
  readonly property string condition: node ? node.state : record ? record.state : ""
  readonly property bool expandable: nesting < 2
  readonly property real now: Omunculus.tick
  // The agents at work below a work that waits on its branch.
  readonly property var workers: {
    if (!node || condition !== "waiting" || !progress)
      return []
    const parents = {}
    for (const each of progress.flat)
      parents[each.work] = each.parent
    const below = each => {
      for (let up = parents[each.work]; up; up = parents[up]) {
        if (up === work)
          return true
      }
      return false
    }
    return Array.from(new Set(progress.flat.filter(each => each.state === "working" && below(each)).map(each => each.agent)))
  }
  // The conversation's own work is named by the masthead.
  readonly property bool titled: title !== Omunculus.subject
  readonly property color stateTone: workers.length > 0 ? Theme.primary : ({
    working: Theme.primary, "needs-you": Theme.warning, stopped: Theme.warning,
    failed: Theme.error, done: Theme.success
  })[condition] || Theme.dim
  readonly property string glyph: workers.length > 0 ? "●" : ({
    working: "●", "needs-you": "⚠", waiting: "○", stopped: "■", failed: "✕", done: "✓", cancelled: "–"
  })[condition] || "○"
  // How the work stands, in words: who works below it, what it waits for, or
  // its state.
  readonly property string word: !node ? condition === "" ? "Handing down…" : condition.charAt(0).toUpperCase() + condition.slice(1)
    : workers.length > 0 ? workers.join(", ") + " working"
    : condition === "waiting" ? node.doing
    : condition === "needs-you" ? node.word.toUpperCase()
    : node.word

  // The status line and the stages, in characters of their font; the status
  // keeps room for its separators.
  readonly property int budget: Math.max(8, Math.floor((width - Theme.size.mark - Theme.size.controlDense - Theme.space.gap) / (metrics.advanceWidth / metrics.text.length)) - 1)
  readonly property var status: Progress.fit([
    { text: glyph + " " + word, keep: true },
    node && node.round > 1 ? { text: "round " + node.round, keep: true } : null,
    node && condition === "working" ? { text: Progress.clock(Math.max(0, now - node.since)), keep: true }
      : node && typeof node.finishedIn === "number" ? { text: "in " + Progress.span(node.finishedIn) }
      : null,
    block.steps !== "" ? { text: block.steps, short: block.steps } : null,
    node && node.failed > 0 ? failures : null
  ].filter(part => part !== null), budget - 15).filter(text => text !== "")
  readonly property var tally: Omunculus.callsOf[work] || {}
  // Its steps with those of the works it handed down, so the count moves
  // while its team works, then how many are its own.
  readonly property string steps: {
    if (!node || (node.branch ? node.branch.calls : node.calls) === 0)
      return ""
    const all = node.branch ? node.branch.calls : node.calls
    const said = count => count === 1 ? "1 step" : count + " steps"
    return all > node.calls ? said(all) + " · " + node.calls + " its own" : said(node.calls)
  }
  // The failed calls: said as retried, in dim, when each of their tools
  // succeeded later; else what was attempted and why the first one failed.
  readonly property var failures: {
    if (!node)
      return null
    const failed = node.failed
    if ((tally.retried || 0) >= failed)
      return { text: failed + " retried" }
    const attempt = failed + " failed" + (tally.firstFailed ? ": " + Phrases.stepFailure(tally.firstFailed, tally.firstArgs) : "")
    return { text: attempt + (tally.firstError ? " (" + tally.firstError + ")" : ""), short: attempt, keep: true }
  }
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

  implicitHeight: present ? content.implicitHeight + Theme.space.tight + Theme.space.row : 0
  // Its own flag: `visible` also follows the page that holds it.
  readonly property bool present: arrived || title !== ""
  visible: present

  TextMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: Theme.type.log.size; text: "MMMMMMMMMM" }

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.tight }
    spacing: Theme.space.tight

    Item {
      id: head
      Layout.fillWidth: true
      Layout.rightMargin: opener.width + Theme.space.gap
      implicitHeight: heading.implicitHeight + lines.implicitHeight + Theme.space.line
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
        spacing: Theme.space.tight
        Item {
          Layout.preferredWidth: Theme.size.mark - heading.spacing
          Layout.preferredHeight: Theme.type.log.size
          Icon { anchors.verticalCenter: parent.verticalCenter; name: "branch"; size: Theme.type.log.size; color: Theme.dim }
        }
        Label { text: "sub-work"; color: Theme.dim; font.pixelSize: Theme.type.log.size }
        Label {
          // The agent stays whole; the title gives way.
          text: block.agent
          color: Omunculus.toneOf(block.agent)
          font.pixelSize: Theme.type.log.size
          elide: Text.ElideRight
        }
        Label {
          visible: block.titled
          Layout.fillWidth: true
          Layout.maximumWidth: implicitWidth
          Layout.minimumWidth: 0
          text: block.title
          color: Theme.foreground
          font.pixelSize: Theme.type.log.size
          elide: Text.ElideRight
        }
        Icon { visible: block.expandable; name: block.expanded ? "chevron-down" : "chevron-right"; size: Theme.type.log.size - 1; color: pointer.containsMouse ? Theme.foreground : Theme.dim }
        Item { Layout.fillWidth: true }
        Label { visible: block.stamp !== ""; text: block.stamp; color: Theme.faint; font.pixelSize: Theme.type.stamp.size; font.letterSpacing: Theme.type.stamp.tracking }
      }

      Column {
        id: lines
        x: Theme.size.mark
        y: heading.height + Theme.space.line
        width: parent.width - x
        spacing: Theme.space.row

        Row {
          spacing: 0
          Repeater {
            model: block.status
            delegate: Label {
              required property string modelData
              required property int index
              text: (index > 0 ? "  ·  " : "") + modelData
              color: index === 0 ? block.stateTone : /^\d+ failed/.test(modelData) && block.condition === "failed" ? Theme.error : Theme.dim
              font.pixelSize: Theme.type.log.size
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
              font.pixelSize: Theme.type.log.size
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
          font.pixelSize: Theme.type.log.size
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
      FocusRing { anchors.margins: -Theme.space.line }
    }

    // Unfolded: the tabs, and what the tab shows, framed under the row.
    SurfaceFrame {
      Layout.fillWidth: true
      Layout.leftMargin: Theme.size.mark
      visible: block.expanded
      implicitHeight: unfolded.implicitHeight + Theme.space.insetTop + Theme.space.inset
      variant: "outline"

      ColumnLayout {
        id: unfolded
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
        spacing: Theme.space.tight
        Flow {
          Layout.fillWidth: true
          Layout.topMargin: Theme.space.line
          visible: block.expanded
          spacing: Theme.space.block
          Repeater {
            model: [{ name: "transcript", text: "TRANSCRIPT" }, { name: "changes", text: "CHANGES" }, { name: "runs", text: "RUNS" }]
            delegate: Tab {
              required property var modelData
              required property int index
              label: modelData.text
              digit: "0" + (index + 1)
              current: block.tab === modelData.name
              onChosen: block.tab = modelData.name
            }
          }
        }

        Loader {
          id: transcript
          Layout.fillWidth: true
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
          Layout.preferredHeight: active ? 320 : 0
          active: block.expanded && block.tab === "changes"
          visible: active
          sourceComponent: WorkChanges { key: block.work }
        }

        Loader {
          Layout.fillWidth: true
          Layout.preferredHeight: active ? 320 : 0
          active: block.expanded && block.tab === "runs"
          visible: active
          sourceComponent: WorkRuns { key: block.work }
        }
      }
    }
  }

  IconButton {
    id: opener
    anchors { right: parent.right; top: parent.top; topMargin: Theme.space.tight }
    name: "open"
    tip: "show this work as a transcript of its own"
    onClicked: block.opened(block.work)
  }
}
