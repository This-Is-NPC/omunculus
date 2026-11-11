pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/client/Progress.js" as Progress
import "kit/client/Time.js" as Time
import "kit/client/Shortcuts.js" as Shortcuts

// ProgressStrip is the conversation's head, which says where it stands: a
// 40 px strip with its state, the workflow of the work in focus and the step
// it is at of how many, and how long it has run — or, before any work, that
// the conversation is starting — then, where there is room, how many agents
// ran and what the conversation has cost, each opening what it counts (the
// tree, the cost); at its right the chevron that opens the full progress, and
// ANSWER, in the warning tone, while something waits on you. Under it,
// unframed, the stages of the work in focus (`Stepper`), or its title where
// the masthead does not already say it, and the chain of agents from the one
// you talk with down to the one at work, each in its tone, behind what the
// conversation is doing: AT WORK, WAITING FOR YOU or WAITING FOR the agents it
// waits for. A finished conversation says "✓ DONE" and how long it took, in
// the success tone. The meta is fitted in characters to its width. The stage
// line is hidden while nothing was handed to anyone and no agent runs, and
// keeps its room once the person has written, so the tabs under it never move
// for it. Waiting on you, the meta says so, in the warning tone, in place of
// the clock, which stops.
ColumnLayout {
  id: strip

  // Omunculus.progress, or null; whether the full view is open.
  property var progress: null
  property bool expanded: false
  // The time of the conversation's newest event, in seconds; 0 when unknown.
  property real lastEvent: 0
  // How many requests wait on you.
  property int waiting: 0
  // What the conversation's model calls used and cost, as the cost view tallies it.
  property var usage: null
  // What the masthead calls the conversation; a title saying the same is not
  // repeated under the strip.
  property string heading: ""

  signal toggle()
  signal answer()
  // The result of a done conversation is wanted.
  signal openResult()
  // The agents counted, or the cost, are wanted.
  signal openTeam()
  signal openCost()

  readonly property string phase: progress ? progress.state : "idle"
  readonly property var focusNode: progress ? progress.focus : null
  readonly property var agents: progress ? progress.agents : []
  readonly property real tick: Omunculus.tick
  readonly property bool working: phase === "working"
  // Whether there is progress to show under the strip.
  readonly property bool moving: progress !== null && (progress.roots.length > 0 || phase !== "idle")
  // The agent the conversation is with.
  readonly property string who: Omunculus.agent || Omunculus.lastAgent
  // Where it stands, for the line of the chain; null before any work.
  readonly property var standing: Progress.standing(progress, who)
  // The focus work's title, when it says what the masthead does not.
  readonly property string title: focusNode && focusNode.steps.length === 0 && focusNode.title !== heading ? focusNode.title : ""

  // What the conversation is doing, ahead of the chain of agents: "" for
  // nothing to say.
  readonly property string doing: !standing ? ""
    : phase === "working" ? "AT WORK"
    : phase === "needs-you" ? "WAITING FOR YOU"
    : phase === "waiting" && standing.waits !== "" ? "WAITING FOR " + standing.waits.toUpperCase() : ""
  // How long the agent at work has been on it.
  readonly property string clock: phase === "working" && progress.now.since !== null && progress.now.since !== undefined ? Progress.clock(Math.max(0, tick - progress.now.since)) : ""

  // Whether the person's message is in the thread, even still sending: the
  // conversation is starting even before its first run shows.
  readonly property bool said: {
    const entries = Omunculus.thread("")
    for (let at = 0; at < entries.count; at++) {
      if (entries.get(at).mine)
        return true
    }
    return false
  }

  // Where the conversation is before any work: starting while its first run
  // goes or once the person has written, working on later ones, not started
  // before any; else its state.
  readonly property string opening: working ? (Omunculus.runs.length <= 1 ? "STARTING" : "WORKING")
    : phase === "idle" ? (Omunculus.runs.length > 0 ? "" : said ? "STARTING" : "NOT STARTED")
    : phase === "needs-you" ? "" : Progress.word(phase).toUpperCase()

  // The meta's parts, for Progress.fit: the workflow gives way to the step's
  // short form; the state, the step and the time stay.
  readonly property var meta: {
    const focus = focusNode
    const here = standing
    const segments = []
    if (phase === "done")
      segments.push({ text: "✓ DONE", tone: Theme.success, keep: true })
    else if (phase === "failed")
      segments.push({ text: "✕ FAILED", tone: Theme.error, keep: true })
    else if (phase === "needs-you")
      segments.push({ text: "NEEDS YOUR ANSWER", short: "NEEDS YOU", tone: Theme.warning, keep: true })
    else if (focus)
      segments.push({ text: Progress.word(phase).toUpperCase() || "OPEN", keep: true })
    else if (opening !== "")
      segments.push({ text: opening, keep: true })
    if (here && here.steps > 0) {
      segments.push({ text: here.workflow.toUpperCase() })
      segments.push({ text: "STEP " + here.step + " OF " + here.steps, short: here.step + "/" + here.steps, keep: true })
      if (here.step < here.steps)
        segments.push({ text: here.steps - here.step + " LEFT" })
    }
    if (focus) {
      // While anything runs, even below a work that is over, the clock counts
      // from the work's start: what was computed at the last event is stale
      // through a long call.
      const took = (focus.finishedIn !== null && !working) || phase === "done"
      const open = !Progress.closed(focus.state) || working
      const lasted = Progress.duration(focus.finishedIn !== null && !working ? focus.finishedIn : open ? Math.max(0, tick - focus.created) : focus.branch.seconds).toUpperCase()
      // Waiting on you stops the clock: it says since when, in the warning tone.
      const since = lastEvent > 0 ? " SINCE " + Time.clock(new Date(lastEvent * 1000).toISOString(), Date.now()) : ""
      if (focus.state === "needs-you" || focus.waitingOn === "you")
        segments.push({ text: "WAITING FOR YOU" + since, short: "WAITING", tone: Theme.warning, keep: true })
      else
        segments.push({ text: took ? "TOOK " + lasted : focus.state === "cancelled" ? lasted : lasted + " SO FAR", short: lasted, keep: true,
          tone: phase === "done" ? Theme.success : undefined })
    }
    const separator = Theme.type.meta.separator
    const shown = segments.filter(segment => segment.text !== "")
    const join = (text, index) => index === 0 ? text : separator + text
    return shown.map((segment, index) => ({
      text: join(segment.text, index), short: segment.short !== undefined ? join(segment.short, index) : undefined,
      keep: segment.keep, tone: segment.tone
    }))
  }

  spacing: Theme.space.line
  Accessible.role: Accessible.StatusBar
  Accessible.name: progress ? progress.spoken : ""

  // A line of parts ({text, short?, elide?, keep?, tone?}) fitted in
  // characters to its width, each part in its tone, else `color`. When a
  // glyph still draws wider than counted, it gives back a character, at most
  // three times. Its implicit width is the whole line's.
  component Fitted: Item {
    id: room
    property var parts: []
    property alias font: line.font
    property color color: Theme.dim
    property int slack: 0
    // A character's pitch on the line, its letter spacing included.
    readonly property real advance: Math.max(1, pitch.advanceWidth / pitch.text.length)
    readonly property int budget: Math.max(1, Math.floor(width / advance + 0.01) - slack)
    readonly property var texts: width > 0 ? Progress.fit(parts, budget) : []
    readonly property string fitted: texts.join("")
    Layout.fillWidth: true
    Layout.minimumWidth: 0
    Layout.maximumWidth: implicitWidth
    implicitWidth: Math.ceil(whole.advanceWidth)
    implicitHeight: line.implicitHeight
    onWidthChanged: slack = 0
    onPartsChanged: slack = 0

    function escaped(text) {
      return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;")
    }
    function painted(text, tone) {
      return text === "" ? "" : "<font color=\"" + (tone || room.color) + "\">" + escaped(text) + "</font>"
    }

    TextMetrics { id: pitch; font: line.font; text: "0000000000" }
    TextMetrics { id: whole; font: line.font; text: room.parts.map(part => part.text || "").join("") }
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
      textFormat: Text.StyledText
      text: room.texts.map((text, index) => room.painted(text, (room.parts[index] || {}).tone)).join("")
      Accessible.name: room.fitted
    }
  }

  // A count in the meta that opens what it counts, after its separator.
  component Count: Item {
    id: count
    property string text
    property string tip
    signal chosen()
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Link
    Accessible.name: text
    Keys.onReturnPressed: chosen()
    Keys.onSpacePressed: chosen()
    Row {
      id: row
      Label {
        text: Theme.type.meta.separator
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
      Label {
        id: word
        text: count.text
        color: pointer.containsMouse || count.activeFocus ? Theme.foreground : Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
        font.underline: pointer.containsMouse
        FocusRing { shown: count.activeFocus; anchors.margins: -Theme.space.row }
        MouseArea {
          id: pointer
          anchors { fill: parent; margins: -Theme.space.tight }
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: count.chosen()
        }
      }
    }
    Hint { active: pointer.containsMouse || count.activeFocus; text: count.tip }
  }

  // The strip: the meta, its counts, and the chevron and the action at its right.
  Rectangle {
    Layout.fillWidth: true
    implicitHeight: Theme.size.strip
    color: "transparent"
    border.color: Theme.line

    RowLayout {
      id: head
      // The counts show where the strip has room for them.
      readonly property bool roomy: Breakpoints.size(width) !== "narrow"
      anchors { fill: parent; leftMargin: Theme.space.inset; rightMargin: Theme.space.trail }
      spacing: Theme.space.tight

      Fitted {
        Layout.fillHeight: true
        parts: strip.meta
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
        // Done, the meta leads to what was delivered.
        activeFocusOnTab: strip.phase === "done"
        Accessible.role: strip.phase === "done" ? Accessible.Link : Accessible.StaticText
        Keys.onReturnPressed: if (strip.phase === "done") strip.openResult()
        Keys.onSpacePressed: if (strip.phase === "done") strip.openResult()
        FocusRing { shown: parent.activeFocus; anchors.margins: -Theme.space.row }
        MouseArea {
          id: delivered
          anchors.fill: parent
          enabled: strip.phase === "done"
          hoverEnabled: true
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: strip.openResult()
        }
        Hint { active: delivered.containsMouse; text: "show what was delivered" }
      }
      // The counts go on with the meta's line, at its own separator.
      Row {
        Layout.alignment: Qt.AlignVCenter
        Layout.leftMargin: -head.spacing
        visible: head.roomy
        Count {
          visible: strip.agents.length > 1
          text: strip.agents.length + " AGENTS"
          tip: strip.agents.slice(0, -1).join(", ") + " and " + strip.agents[strip.agents.length - 1] + " ran here; open the team"
          onChosen: strip.openTeam()
        }
        Count {
          visible: !!strip.usage && strip.usage.priced > 0
          text: strip.usage ? Omunculus.money(strip.usage.cost) : ""
          tip: "what this conversation has cost; open the cost"
          onChosen: strip.openCost()
        }
      }
      Item { Layout.fillWidth: true }
      IconButton {
        Layout.alignment: Qt.AlignVCenter
        visible: strip.moving
        name: strip.expanded ? "chevron-up" : "chevron-down"
        tip: (strip.expanded ? "close" : "open") + " the progress of the works  " + Shortcuts.label("progress")
        highlighted: strip.expanded
        onClicked: strip.toggle()
      }
      TraceButton {
        Layout.alignment: Qt.AlignVCenter
        visible: strip.waiting > 0
        dense: true
        role: "progress"
        tone: Theme.warning
        icon: "enter"
        text: "ANSWER" + (strip.waiting > 1 ? "  " + strip.waiting : "")
        tip: "answer the newest question waiting on you" + (strip.waiting > 1 ? ", of " + strip.waiting : "") + "  " + Shortcuts.label("reply")
        onClicked: strip.answer()
      }
    }
  }

  // The stages of the work in focus, else its title.
  Stepper {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving && steps.length > 0
    size: 12
    steps: strip.focusNode ? strip.focusNode.steps : []
    round: strip.focusNode ? strip.focusNode.round : 0
    tip: strip.focusNode ? strip.focusNode.title : ""
  }
  Label {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving && strip.title !== ""
    text: strip.title
    color: Theme.foreground
    font.pixelSize: Theme.type.body.size
    font.bold: true
    elide: Text.ElideRight
  }

  // The agents from the one you talk with down to the one at work, behind
  // what the conversation is doing.
  Flow {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving && strip.doing !== ""
    spacing: Theme.space.tight
    Label {
      text: strip.doing
      color: strip.phase === "needs-you" ? Theme.warning : Theme.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: Theme.type.meta.tracking
    }
    Repeater {
      model: strip.standing ? strip.standing.chain : []
      delegate: Row {
        id: link
        required property string modelData
        required property int index
        spacing: Theme.space.tight
        Label {
          text: link.modelData
          color: Omunculus.toneOf(link.modelData)
          font.pixelSize: Theme.type.body.size
          font.bold: link.modelData === strip.standing.agent
        }
        Label {
          visible: link.modelData !== strip.standing.agent
          text: "›"
          color: Theme.dim
          font.pixelSize: Theme.type.body.size
        }
      }
    }
    Label {
      visible: strip.clock !== ""
      text: strip.clock
      color: Theme.dim
      font.pixelSize: Theme.type.meta.size
    }
  }

  // The line of the stages or title, kept blank once the person has written,
  // so the tabs hold their place as the first run starts.
  Item {
    Layout.fillWidth: true
    visible: strip.said && !(strip.moving && ((strip.focusNode && strip.focusNode.steps.length > 0) || strip.title !== ""))
    implicitHeight: stageLine.height
    FontMetrics { id: stageLine; font.family: Theme.fontFamily; font.pixelSize: 12 }
  }
}
