pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/client/Progress.js" as Progress
import "kit/client/Shortcuts.js" as Shortcuts

// ProgressStrip is the conversation's head: a 40 px strip with its meta —
// the agent it is with, the stage of the work in focus, how long it has run,
// how many agents and model calls — and its action at the right: ANSWER,
// in the warning tone, while something waits on you, else PROGRESS once there
// is a work. Under it, unframed, two lines: the stages of the work in focus,
// with the chevron that opens the full view, and who works on it, from its
// agent down to the one at work, what that one does and for how long; a
// question waiting on you takes that line, and a finished work says how long
// it took. Every line is fitted in characters to its width. The two lines
// are hidden while nothing was handed to anyone and no agent runs.
ColumnLayout {
  id: strip

  // Omunculus.progress, or null; whether the full view is open.
  property var progress: null
  property bool expanded: false
  // The time of the conversation's newest event, in seconds; 0 when unknown.
  property real lastEvent: 0
  // How many requests wait on you.
  property int waiting: 0
  // The model calls of the conversation.
  property int calls: 0
  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  signal toggle()
  signal answer()

  readonly property string phase: progress ? progress.state : "idle"
  readonly property var focusNode: progress ? progress.focus : null
  readonly property var forYou: progress ? progress.forYou : []
  readonly property var path: progress ? progress.path : []
  readonly property var now: progress ? progress.now : null
  readonly property real tick: Omunculus.tick
  readonly property bool working: phase === "working"
  readonly property int silence: working && lastEvent > 0 ? Math.round(tick - lastEvent) : 0
  // Whether there is progress to show under the strip.
  readonly property bool moving: progress !== null && (progress.roots.length > 0 || phase !== "idle")

  // The meta's parts, for Progress.fit: the counts give way first, then the
  // agent; the stage and the time stay.
  readonly property var meta: {
    const focus = focusNode
    const segments = [{ text: (Omunculus.agent || Omunculus.lastAgent).toUpperCase(), lead: true }]
    if (focus && focus.count > 0) {
      const at = Math.min(focus.at, focus.count - 1)
      segments.push({ text: "STAGE " + (at + 1) + " OF " + focus.count + " " + String(focus.steps[at].name).toUpperCase(), short: "STAGE " + (at + 1) + "/" + focus.count, keep: true })
    }
    if (focus)
      segments.push({ text: Progress.span(focus.finishedIn !== null ? focus.finishedIn : focus.branch.seconds).toUpperCase(), keep: true })
    const agents = progress ? progress.counts.agents : 0
    if (agents > 0)
      segments.push({ text: agents + (agents === 1 ? " AGENT" : " AGENTS") })
    if (calls > 0)
      segments.push({ text: calls + (calls === 1 ? " CALL" : " CALLS") })
    // The agent carries the separator after it, so it goes with it; the
    // others carry the one before them.
    const separator = Theme.type.meta.separator
    const shown = segments.filter(segment => segment.text !== "")
    const join = (text, index) => shown[index].lead ? text + (shown.length > 1 ? separator : "")
      : index === 0 || shown[index - 1].lead ? text : separator + text
    return shown.map((segment, index) => ({
      text: join(segment.text, index), short: segment.short !== undefined ? join(segment.short, index) : undefined, keep: segment.keep
    }))
  }

  // The now line's parts: the chain above the agent at work gives way
  // first, then what it does; the agent and the clock stay.
  readonly property var parts: {
    if (forYou.length > 0) {
      const asker = forYou[0].asker
      const asks = forYou.filter(ask => ask.asker === asker).length
      return [{ text: asker + " asks you", elide: true, keep: true },
              { text: " · " + asks + (asks === 1 ? " question" : " questions"), keep: true }]
    }
    if (phase === "done") {
      const took = focusNode ? focusNode.finishedIn || focusNode.branch.seconds : 0
      return [{ text: "Finished", keep: true }, { text: " · took " + Progress.span(took) }]
    }
    if (!now || !now.agent)
      return [{ text: focusNode ? focusNode.doing : "", elide: true, keep: true }]
    const above = path.map(step => step.agent).filter(agent => agent && agent !== now.agent)
    const clock = now.since !== null && working ? Progress.clock(Math.max(0, Math.round(tick - now.since))) : ""
    return (above.length > 0 ? [{ text: above.join(" › ") + " › ", short: "…› " }] : [])
      .concat([{ text: now.agent, keep: true }, { text: ": " + now.doing, elide: true }])
      .concat(clock !== "" ? [{ text: " · " + clock, keep: true }] : [])
  }

  readonly property string stall: silence > quiet ? " · no news for " + Progress.span(silence) : ""

  spacing: Theme.space.line
  Accessible.role: Accessible.StatusBar
  Accessible.name: progress ? progress.spoken : ""

  // A line of parts fitted in characters to its width; when a glyph still
  // draws wider than counted, it gives back a character, at most three times.
  component Fitted: Item {
    id: room
    property var parts: []
    property alias font: line.font
    property alias color: line.color
    property int slack: 0
    readonly property int budget: Math.max(1, Math.floor(width / Math.max(1, metrics.advanceWidth("0") + line.font.letterSpacing)) - slack)
    readonly property string fitted: width > 0 ? Progress.fit(parts, budget).join("") : ""
    Layout.fillWidth: true
    Layout.minimumWidth: 0
    implicitHeight: line.implicitHeight
    onWidthChanged: slack = 0
    onPartsChanged: slack = 0
    FontMetrics { id: metrics; font: line.font }
    TextMetrics {
      id: drawn
      font: line.font
      text: room.fitted
      onAdvanceWidthChanged: Qt.callLater(() => { if (drawn.advanceWidth > room.width + 0.5 && room.slack < 3) room.slack++ })
    }
    Label {
      id: line
      width: room.width
      anchors.verticalCenter: parent.verticalCenter
      text: room.fitted
      elide: Text.ElideRight
    }
  }

  // The strip: the meta, and the action at its right.
  Rectangle {
    Layout.fillWidth: true
    implicitHeight: Theme.size.strip
    color: "transparent"
    border.color: Theme.line

    RowLayout {
      anchors { fill: parent; leftMargin: Theme.space.inset; rightMargin: Theme.space.trail }
      spacing: Theme.space.gap

      Fitted {
        Layout.fillHeight: true
        parts: strip.meta
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
      TraceButton {
        Layout.alignment: Qt.AlignVCenter
        visible: strip.waiting > 0 || strip.moving
        dense: true
        role: "progress"
        tone: strip.waiting > 0 ? Theme.warning : Theme.primary
        icon: strip.waiting > 0 ? "enter" : "list"
        text: strip.waiting > 0 ? "ANSWER" + (strip.waiting > 1 ? "  " + strip.waiting : "") : "PROGRESS"
        tip: strip.waiting > 0 ? "answer the newest question waiting on you" + (strip.waiting > 1 ? ", of " + strip.waiting : "") + "  " + Shortcuts.label("reply")
          : (strip.expanded ? "close" : "open") + " the progress of the works  " + Shortcuts.label("progress")
        onClicked: strip.waiting > 0 ? strip.answer() : strip.toggle()
      }
    }
  }

  // The stages of the work in focus, else its title; the chevron opens the
  // full view.
  RowLayout {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving
    spacing: Theme.space.gap

    Stepper {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      visible: steps.length > 0
      size: 12
      steps: strip.focusNode ? strip.focusNode.steps : []
      round: strip.focusNode ? strip.focusNode.round : 0
      tip: strip.focusNode ? strip.focusNode.title : ""
    }
    Label {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      visible: !strip.focusNode || strip.focusNode.steps.length === 0
      text: strip.focusNode ? strip.focusNode.title : Omunculus.subject
      color: Theme.foreground
      font.pixelSize: Theme.type.body.size
      font.bold: true
      elide: Text.ElideRight
    }
    IconButton {
      Layout.alignment: Qt.AlignVCenter
      name: strip.expanded ? "chevron-up" : "chevron-down"
      tip: (strip.expanded ? "close" : "open") + " the progress"
      highlighted: strip.expanded
      onClicked: strip.toggle()
    }
  }

  // Who works and what on, fitted, after the state; the silence, when long, after it.
  RowLayout {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving
    spacing: Theme.space.tight

    // The state: the trace while working, unless motion is reduced.
    Item {
      Layout.preferredWidth: Theme.size.gutter
      Layout.preferredHeight: Theme.type.meta.size
      Layout.alignment: Qt.AlignVCenter
      LoadingTrace {
        anchors.fill: parent
        running: strip.working && !Theme.reducedMotion
        tone: Theme.primary
      }
      StateMark {
        anchors.centerIn: parent
        visible: !strip.working || Theme.reducedMotion
        state: strip.working ? "" : strip.forYou.length > 0 ? "needs-you" : strip.phase
        showWord: false
      }
    }
    Fitted {
      parts: strip.parts
      color: strip.forYou.length > 0 ? Theme.warning : Theme.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: Theme.type.meta.tracking / 2
    }
    Label {
      visible: strip.stall !== ""
      Layout.maximumWidth: strip.width * 0.4
      text: strip.stall
      elide: Text.ElideRight
      color: Theme.warning
      font.pixelSize: Theme.type.meta.size
    }
  }
}
