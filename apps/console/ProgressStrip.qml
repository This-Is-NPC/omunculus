pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/client/Progress.js" as Progress
import "kit/client/Time.js" as Time
import "kit/client/Shortcuts.js" as Shortcuts

// ProgressStrip is the conversation's head: a 40 px strip with its meta —
// the agent it is with, in its tone; the stage of the work in focus (the
// stepper under names it) and how long it has run, or, before any work, that the conversation is starting —
// then, where there is room, how many agents ran and what the
// conversation has cost, each opening what it counts (the team, the cost); at its right
// the chevron that opens the full progress, and ANSWER, in the warning tone,
// while something waits on you. Under it, unframed, two lines: the stages of
// the work in focus, or its title where the masthead does not already say
// it; and who works on it, from its agent down to the one at work, what that
// one does and for how long; what waits on you takes that line, counted as
// its card counts it, and a finished work says how long it took. Every agent
// is named in its own tone. Every line is fitted in characters to its width.
// The two lines are hidden while nothing was handed to anyone and no agent
// runs; the second also while the thread under the strip shows its own
// working row, so the work is said once. Waiting on you, the meta says so,
// in the warning tone, in place of the clock, which stops.
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
  // Whether the thread beside already says who works and on what, so the
  // strip does not say it again.
  property bool threadWorking: false
  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  signal toggle()
  signal answer()
  // The agents counted, or the cost, are wanted.
  signal openTeam()
  signal openCost()

  readonly property string phase: progress ? progress.state : "idle"
  readonly property var focusNode: progress ? progress.focus : null
  readonly property var forYou: progress ? progress.forYou : []
  readonly property var path: progress ? progress.path : []
  readonly property var now: progress ? progress.now : null
  readonly property var agents: progress ? progress.agents : []
  readonly property real tick: Omunculus.tick
  readonly property bool working: phase === "working"
  readonly property int silence: working && lastEvent > 0 ? Math.round(tick - lastEvent) : 0
  // Whether there is progress to show under the strip.
  readonly property bool moving: progress !== null && (progress.roots.length > 0 || phase !== "idle")
  // The agent the conversation is with.
  readonly property string who: Omunculus.agent || Omunculus.lastAgent
  // The focus work's title, when it says what the masthead does not.
  readonly property string title: focusNode && focusNode.steps.length === 0 && focusNode.title !== heading ? focusNode.title : ""

  // Whether a message of the person's is on its way.
  property bool sending: false
  // Whether the person's message is in the thread or on its way: the
  // conversation is starting even before its first run shows.
  readonly property bool said: {
    if (sending)
      return true
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
  readonly property string opening: working ? (threadWorking ? "" : Omunculus.runs.length <= 1 ? "STARTING" : "WORKING")
    : phase === "idle" ? (Omunculus.runs.length > 0 ? "" : said ? "STARTING" : "NOT STARTED")
    : phase === "needs-you" ? "" : Progress.word(phase).toUpperCase()

  // The meta's parts, for Progress.fit: the stage gives way to its short
  // form, then the agent; the stage and the time stay.
  readonly property var meta: {
    const focus = focusNode
    const segments = who !== "" ? [{ text: who.toUpperCase(), tone: Omunculus.toneOf(who), lead: true }] : []
    if (focus && focus.count > 0) {
      const at = Math.min(focus.at, focus.count - 1)
      // The stepper under the strip names the stage.
      segments.push({ text: "STAGE " + (at + 1) + "/" + focus.count, keep: true })
    } else if (focus && focus.state !== "needs-you" && !(threadWorking && focus.state === "working")) {
      segments.push({ text: focus.word.toUpperCase(), keep: true })
    } else if (opening !== "") {
      segments.push({ text: opening, keep: true })
    }
    if (focus) {
      const took = focus.finishedIn !== null
      const lasted = Progress.duration(took ? focus.finishedIn : focus.branch.seconds).toUpperCase()
      // Waiting on you stops the clock: it says since when, in the warning tone.
      const since = lastEvent > 0 ? " SINCE " + Time.clock(new Date(lastEvent * 1000).toISOString(), Date.now()) : ""
      if (focus.state === "needs-you")
        segments.push({ text: "WAITING FOR YOU" + since, short: "WAITING", tone: Theme.warning, keep: true })
      else
        segments.push({ text: took ? "TOOK " + lasted : focus.state === "cancelled" ? lasted : lasted + " SO FAR", short: lasted, keep: true })
    }
    // The agent carries the separator after it, so it goes with it; the
    // others carry the one before them.
    const separator = Theme.type.meta.separator
    const shown = segments.filter(segment => segment.text !== "")
    const join = (text, index) => shown[index].lead ? text + (shown.length > 1 ? separator : "")
      : index === 0 || shown[index - 1].lead ? text : separator + text
    return shown.map((segment, index) => ({
      text: join(segment.text, index), short: segment.short !== undefined ? join(segment.short, index) : undefined,
      keep: segment.keep, tone: segment.tone,
      pieces: segment.lead && shown.length > 1 ? [{ text: segment.text, tone: segment.tone }, { text: separator }] : undefined
    }))
  }

  // The now line's parts: the chain above the agent at work gives way
  // first, then what it does; the agent and the clock stay.
  readonly property var parts: {
    if (forYou.length > 0) {
      const askers = Array.from(new Set(forYou.map(ask => ask.asker)))
      const named = askers.map((name, index) => ({ text: name + (index < askers.length - 1 ? ", " : ""), tone: Omunculus.toneOf(name),
        pieces: index < askers.length - 1 ? [{ text: name, tone: Omunculus.toneOf(name) }, { text: ", " }] : undefined, elide: index === 0, keep: true }))
      return named.concat([{ text: (askers.length > 1 ? " ask you " : " asks you ") + Progress.asking(forYou), tone: Theme.warning, keep: true }])
    }
    if (phase === "done") {
      const took = focusNode ? focusNode.finishedIn || focusNode.branch.seconds : 0
      return [{ text: "Finished", keep: true }, { text: " · took " + Progress.duration(took) }]
    }
    if (!now || !now.agent)
      return [{ text: focusNode ? focusNode.doing : "", elide: true, keep: true }]
    const above = now.loose ? [] : path.map(step => step.agent).filter(agent => agent && agent !== now.agent)
    const clock = now.since !== null && working ? Progress.clock(Math.max(0, Math.round(tick - now.since))) : ""
    const chain = above.reduce((all, agent) => all.concat([{ text: agent, tone: Omunculus.toneOf(agent) }, { text: " › " }]), [])
    return (above.length > 0 ? [{ text: chain.map(piece => piece.text).join(""), short: "…› ", pieces: chain }] : [])
      .concat([{ text: now.agent, tone: Omunculus.toneOf(now.agent), keep: true }, { text: ": " + now.doing, elide: true }])
      .concat(clock !== "" ? [{ text: " · " + clock, keep: true }] : [])
  }

  readonly property string stall: silence > quiet ? " · no news for " + Progress.duration(silence) : ""

  spacing: Theme.space.line
  Accessible.role: Accessible.StatusBar
  Accessible.name: progress ? progress.spoken : ""

  // A line of parts ({text, short?, elide?, keep?, tone?, pieces?}) fitted
  // in characters to its width, each part in its tone, else `color`; a part
  // shown whole draws its `pieces`, each in its own. When a glyph still draws
  // wider than counted, it gives back a character, at most three times.
  // Its implicit width is the whole line's.
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
      text: room.texts.map((text, index) => {
        const part = room.parts[index] || {}
        return part.pieces && text === part.text ? part.pieces.map(piece => room.painted(piece.text, piece.tone)).join("") : room.painted(text, part.tone)
      }).join("")
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

      Dot {
        Layout.alignment: Qt.AlignVCenter
        visible: strip.who !== ""
        tone: Omunculus.toneOf(strip.who)
      }
      Fitted {
        Layout.fillHeight: true
        parts: strip.meta
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
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

  // Who works and what on, fitted, after the state; the silence, when long,
  // after it. While the thread shows who works, the line keeps its room
  // blank, so nothing under it moves as runs start and end.
  RowLayout {
    Layout.fillWidth: true
    Layout.leftMargin: Theme.space.line
    visible: strip.moving
    opacity: strip.threadWorking ? 0 : 1
    spacing: Theme.space.tight

    // The state: the trace while working, unless motion is reduced.
    Item {
      readonly property bool traced: strip.working && !Theme.reducedMotion
      Layout.preferredWidth: traced ? Theme.size.gutter : mark.implicitWidth
      Layout.preferredHeight: Theme.type.meta.size
      Layout.alignment: Qt.AlignVCenter
      LoadingTrace {
        anchors.fill: parent
        running: parent.traced
        tone: Theme.primary
      }
      StateMark {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        visible: !parent.traced
        state: strip.working ? "working" : strip.forYou.length > 0 ? "needs-you" : strip.phase
        showWord: false
      }
    }
    Fitted {
      parts: strip.parts
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
    Item { Layout.fillWidth: true }
  }
}
