pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/client/Progress.js" as Progress

// ProgressNode is one work of a Progress tree, in one of two forms.
//
// "compact", in the chat's progress: an open work (working, needs you,
// waiting, stopped, failed) is a framed card — its agent and state, its
// title, its stages, what it calls or does, a send-back with its reason, the
// questions it asked and its steps; a done, cancelled or coming work is
// one line. Picked, it shows its details instead of the questions' first
// lines: its agent's last words, its questions in full and the ways to its
// thread, log and map.
//
// "full", a row of the TEAM page, as a table row: its title with its state at
// the top right, a meta line of its agent, its stages (a track on a narrow
// window), its branch's time, steps and cost and what is below it, and a
// badge for each request between it and others — its climb, "⇡ seller ›
// sales › you"; the one to you in the warning tone — and for a work below it
// that needs you. A row with works
// below it has a tool at its right that goes down to them.
FocusScope {
  id: row

  // A node of Omunculus.progress.
  required property var node
  property string mode: "compact"
  // Compact: on the path from the focus root to the active leaf. Full: the
  // row picked.
  property bool active: false
  // At one end of the request picked elsewhere, as on the TEAM page.
  property bool highlighted: false
  // Compact: its details show.
  property bool expanded: false
  // It has works below it: compact, folded away or not; full, a level down.
  property bool folds: false
  property bool folded: false
  // Full: the keyboard is on this row of its list.
  property bool focused: false

  signal toggled()
  signal foldToggled()
  // Full: its row tool, to the works below it.
  signal drilled()
  signal openThread(string work)
  signal openLog(string work)
  signal openMap(string work)
  // A request badge, by request id ("full" only).
  signal requestPicked(string id)

  readonly property bool full: mode === "full"
  readonly property bool ongoing: !["done", "cancelled"].includes(node.state)
  readonly property bool quiet: ["done", "cancelled", "up-next"].includes(node.state)
  readonly property real now: Omunculus.tick
  readonly property color agentTone: Omunculus.toneOf(node.agent)
  readonly property var steps: node.steps
  readonly property var asks: node.asks
  readonly property var asked: node.asked
  // The works working below a work that waits on them: it reads as them at
  // work, not as blocked.
  readonly property var underway: node.state === "waiting" ? Progress.underway(node) : []
  readonly property bool busy: underway.length > 0
  readonly property string shownState: busy ? "working" : node.state
  readonly property string asWords: busy
    ? Array.from(new Set(underway.map(each => each.agent))).join(", ") + " working"
    : node.state === "waiting" || node.state === "working" ? node.doing : ""
  // The state's words, the state's own when who works does not fit its room.
  readonly property string saying: asWords !== "" && markFont.advanceWidth(asWords) <= rowBody.width * 0.55 - Theme.space.cell - Theme.space.line ? asWords : ""
  readonly property string clock: node.state === "working" && node.since !== null
    ? Progress.clock(Math.max(0, Math.round(now - node.since))) : ""

  // The newest words in the work's thread, newest last, while its details show.
  readonly property ListModel said: Omunculus.thread(expanded ? Omunculus.threadOf(node.work) : "")
  readonly property var words: {
    if (!expanded)
      return []
    const found = []
    for (let at = said.count - 1; at >= 0 && found.length < 3; at--) {
      const entry = said.get(at)
      if (entry.text && entry.who === node.agent)
        found.unshift(entry.text)
    }
    return found
  }

  // A tally's money when the provider priced it, else its tokens, worded as
  // the cost page does.
  function spent(usage) {
    if (usage.calls === 0)
      return ""
    return usage.priced > 0 ? Omunculus.money(usage.cost) : Omunculus.tokens(usage.input) + " read" + Theme.type.meta.separator + Omunculus.tokens(usage.output) + " written"
  }

  // Full: the branch's time and cost, the work's own steps (tool calls) and
  // what is below it, as parts that give way whole, last first.
  readonly property var totals: {
    if (!full)
      return []
    const branch = node.branch
    const below = Progress.below(Progress.kidsOf(node))
    const parts = below !== "" ? [below] : []
    parts.push(node.finishedIn !== null ? "took " + Progress.span(node.finishedIn)
      : Progress.span(ongoing ? Math.max(0, now - node.created) : branch.seconds))
    if (node.calls > 0)
      parts.push(node.calls + (node.calls === 1 ? " step" : " steps"))
    const money = spent(branch.usage)
    if (money !== "")
      parts.push(money)
    return parts
  }

  // Incoming requests, one badge per agent asking.
  readonly property var askedBy: {
    const by = {}
    for (const request of asked)
      (by[request.from] = by[request.from] || []).push(request)
    return Object.keys(by).map(from => ({ from: from, requests: by[from] }))
  }

  readonly property string stageTip: {
    const lane = Omunculus.laneOf(Omunculus.work(node.work) || {})
    const at = steps.findIndex(step => step.status === "current")
    return lane && at >= 0 ? lane.name + " · stage " + (at + 1) + " of " + steps.length + ": " + steps[at].name : ""
  }

  FontMetrics { id: markFont; font: stateMark.font }

  implicitWidth: 240
  implicitHeight: full ? rowBody.implicitHeight + Theme.space.cell * 2
    : (quiet ? line.implicitHeight + Theme.space.tight * 2 : card.implicitHeight + Theme.space.gap * 2)
      + (expanded ? more.implicitHeight + Theme.space.gap : 0)
  // A row of the TEAM page is moved over by its list, never a Tab stop.
  activeFocusOnTab: !full
  Accessible.role: Accessible.Button
  Accessible.name: node.agent + ", " + node.word + (node.title ? ", " + node.title : "")
  Keys.onReturnPressed: toggled()
  Keys.onSpacePressed: toggled()

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (!row.full)
        row.forceActiveFocus()
      row.toggled()
    }
  }

  // Full: a row of the TEAM page.
  Rectangle {
    visible: row.full
    anchors.fill: parent
    color: row.active ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
    border.color: row.highlighted ? Theme.warning : row.active ? Theme.primary : Theme.line
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  ColumnLayout {
    id: rowBody
    visible: row.full
    anchors {
      left: parent.left; right: parent.right; top: parent.top
      leftMargin: Theme.space.cell; topMargin: Theme.space.cell
      rightMargin: Theme.space.cell + (drill.visible ? drill.width + Theme.space.trail : 0)
    }
    spacing: Theme.space.tight

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.node.title || row.node.agent
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        elide: Text.ElideRight
      }
      // The state, at the top right.
      StateMark {
        id: stateMark
        Layout.alignment: Qt.AlignTop
        Layout.fillWidth: false
        Layout.maximumWidth: rowBody.width * 0.55
        state: row.shownState
        text: row.saying
        clock: row.clock
      }
    }

    // Its agent, its stages, its branch. The branch's totals give way first,
    // then the stages, so the agent and where it is stay.
    RowLayout {
      id: meta
      // A narrow window shows the stages as a track.
      readonly property bool tight: Breakpoints.size(row.Window.width) === "narrow"
      readonly property real agentWidth: Math.min(agent.implicitWidth, rowBody.width * 0.3)
      readonly property real stagesRoom: Math.max(0, rowBody.width - agentWidth - (separator.visible ? separator.implicitWidth : 0))
      readonly property real stagesWidth: row.steps.length === 0 ? 0
        : tight ? Math.min(stagesRoom, track.Layout.preferredWidth + track.Layout.rightMargin + stage.implicitWidth)
        : Math.min(stagesRoom, stepper.natural)
      Layout.fillWidth: true
      spacing: 0
      Label {
        id: agent
        Layout.preferredWidth: meta.agentWidth
        text: row.node.agent
        color: row.agentTone
        font.pixelSize: Theme.type.meta.size
        elide: Text.ElideRight
      }
      Label {
        id: separator
        visible: row.steps.length > 0
        text: Theme.type.meta.separator
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
      }
      Stepper {
        id: stepper
        Layout.preferredWidth: meta.stagesWidth
        visible: row.steps.length > 0 && !meta.tight
        steps: row.steps
        round: row.node.round
        size: Theme.type.meta.size
        tip: row.stageTip
      }
      // The stages as a track, and the stage it is at.
      ProgressTrack {
        id: track
        visible: row.steps.length > 0 && meta.tight
        Layout.preferredWidth: Theme.size.control
        Layout.preferredHeight: Theme.space.tight
        Layout.rightMargin: Theme.space.tight
        fraction: row.node.state === "done" ? 1 : row.node.count > 0 ? row.node.at / row.node.count : 0
      }
      Label {
        id: stage
        visible: row.steps.length > 0 && meta.tight
        // The stage's name gives way whole, leaving its place: "2/4".
        text: {
          if (row.node.at < 0)
            return ""
          const place = (row.node.at + 1) + "/" + row.node.count
          const full = place + " " + row.steps[row.node.at].name + (row.node.round > 0 ? " r" + row.node.round : "")
          return metrics.advanceWidth(full) <= meta.stagesRoom - track.Layout.preferredWidth - track.Layout.rightMargin ? full : place
        }
        color: Theme.primary
        font.pixelSize: Theme.type.meta.size
      }
      Label {
        id: totalsLabel
        readonly property real room: Math.max(0, meta.stagesRoom - meta.stagesWidth)
        // The longest run of the parts, from the first, that fits.
        text: {
          for (let count = row.totals.length; count > 0; count--) {
            const shown = Theme.type.meta.separator + row.totals.slice(0, count).join(Theme.type.meta.separator)
            if (metrics.advanceWidth(shown) <= room)
              return shown
          }
          return ""
        }
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
      }
      FontMetrics { id: metrics; font: totalsLabel.font }
      Item { Layout.fillWidth: true }
    }

    // What waits between it and others, and below it.
    Flow {
      Layout.fillWidth: true
      visible: row.asks.length > 0 || row.askedBy.length > 0 || row.node.below !== ""
      spacing: Theme.space.tight
      Repeater {
        model: row.full ? row.asks : []
        delegate: Chip {
          required property var modelData
          text: "⇡ " + modelData.chain.join(" › ")
          accent: modelData.human ? Theme.warning : Theme.primary
          alert: modelData.human
          tip: modelData.question.split("\n")[0]
          onClicked: row.requestPicked(modelData.id)
        }
      }
      Repeater {
        model: row.full ? row.askedBy : []
        delegate: Chip {
          required property var modelData
          text: "⇣ " + modelData.requests.length + (modelData.requests.length === 1 ? " question" : " questions") + " from " + modelData.from
          tip: modelData.requests[0].question.split("\n")[0]
          onClicked: row.requestPicked(modelData.requests[0].id)
        }
      }
      // A work below waits on you; this one keeps its own state.
      Chip {
        visible: row.full && row.node.below !== ""
        text: "⇣ needs you below"
        accent: Theme.warning
        onClicked: row.requestPicked(row.node.below)
      }
    }
  }

  IconButton {
    id: drill
    visible: row.full && row.folds
    anchors { right: parent.right; rightMargin: Theme.space.trail; verticalCenter: parent.verticalCenter }
    name: "open"
    quiet: true
    highlighted: row.active
    tip: "open its level: the works it handed down"
    // A row is moved over by its list; its tool is pointed at.
    activeFocusOnTab: false
    onClicked: row.drilled()
  }

  // Full: the keyboard's row.
  FocusRing { visible: row.full; shown: row.focused }

  // Compact: the card's frame, or a wash over a one-line work.
  SurfaceFrame {
    id: frame
    anchors.fill: parent
    visible: !row.full && (!row.quiet || row.expanded || row.highlighted)
    tone: row.highlighted ? Theme.warning : head.tone
    active: row.active || row.highlighted
    color: pointer.containsMouse ? Theme.highlight : fill
  }
  Rectangle {
    anchors.fill: parent
    visible: !row.full && row.quiet && !frame.visible && pointer.containsMouse
    color: Theme.highlight
  }

  // A done, cancelled or coming work: one line.
  RowLayout {
    id: line
    visible: !row.full && row.quiet
    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: Theme.space.gap; rightMargin: Theme.space.line; topMargin: Theme.space.tight }
    spacing: Theme.space.tight
    StateMark { state: row.node.state; showWord: false }
    Label {
      Layout.maximumWidth: line.width * 0.4
      text: row.node.agent
      color: row.agentTone
      font.pixelSize: Theme.type.body.size
      font.bold: true
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      readonly property string said: row.node.doing || row.node.word
      text: row.node.title + (said !== "" ? " · " + said.charAt(0).toLowerCase() + said.slice(1) : "")
      color: Theme.dim
      font.pixelSize: Theme.type.tab.size
      elide: Text.ElideRight
    }
    Fold { visible: row.folds; folded: row.folded; onPressed: { row.forceActiveFocus(); row.foldToggled() } }
  }

  // The fold of the works below it.
  component Fold: Item {
    id: fold
    property bool folded: false
    signal pressed()
    Layout.preferredWidth: Theme.size.gutter
    Layout.preferredHeight: Theme.size.gutter
    Layout.alignment: Qt.AlignTop
    Icon {
      anchors.centerIn: parent
      name: fold.folded ? "chevron-right" : "chevron-down"
      size: 12
      color: Theme.dim
    }
    MouseArea {
      anchors { fill: parent; margins: -4 }
      cursorShape: Qt.PointingHandCursor
      onClicked: fold.pressed()
    }
  }

  // An open work: the card.
  ColumnLayout {
    id: card
    visible: !row.full && !row.quiet
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.gap }
    spacing: Theme.space.line

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      Dot { Layout.alignment: Qt.AlignVCenter; tone: row.agentTone }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.node.agent.toUpperCase()
        color: row.agentTone
        font.pixelSize: Theme.type.name.size
        font.letterSpacing: Theme.type.name.tracking
        elide: Text.ElideRight
      }
      StateMark {
        id: head
        Layout.maximumWidth: card.width * 0.55
        state: row.node.state
        clock: row.clock
      }
      Fold { visible: row.folds; folded: row.folded; onPressed: { row.forceActiveFocus(); row.foldToggled() } }
    }

    Label {
      Layout.fillWidth: true
      visible: text !== ""
      text: row.node.title
      color: Theme.foreground
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    Stepper {
      Layout.fillWidth: true
      steps: row.steps
      round: row.node.round
      tip: row.stageTip
    }

    // The tool it called last, else what it is doing.
    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      Label {
        visible: !!row.node.lastCall
        Layout.maximumWidth: card.width * 0.4
        text: row.node.lastCall ? row.node.lastCall.name : ""
        color: Theme.foreground
        font.pixelSize: Theme.type.tab.size
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.node.lastCall ? row.node.lastCall.brief : row.node.doing
        color: row.node.state === "failed" ? Theme.error : row.node.state === "stopped" || row.node.state === "needs-you" ? Theme.warning : Theme.dim
        font.pixelSize: Theme.type.tab.size
        elide: Text.ElideRight
      }
    }

    Label {
      Layout.fillWidth: true
      visible: row.node.round > 0
      text: "↩ Round " + row.node.round + (row.node.sentBack ? " · sent back by " + row.node.sentBack.by
        + (row.node.sentBack.why ? ": \"" + row.node.sentBack.why + "\"" : "") : "")
      color: Theme.dim
      font.pixelSize: Theme.type.tab.size
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }

    // The first line of each question it asked; its details show them whole.
    Repeater {
      model: row.expanded ? [] : row.asks
      delegate: RowLayout {
        id: ask
        required property var modelData
        Layout.fillWidth: true
        spacing: Theme.space.tight
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: "? asked " + (ask.modelData.human ? "you" : ask.modelData.to) + ": \"" + ask.modelData.question.split("\n")[0] + "\""
          color: ask.modelData.human ? Theme.warning : Theme.foreground
          font.pixelSize: Theme.type.tab.size
          elide: Text.ElideRight
        }
        Label { text: "waiting"; color: Theme.dim; font.pixelSize: Theme.type.tab.size }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: row.node.calls > 0
      spacing: 0
      Label {
        text: row.node.calls + (row.node.calls === 1 ? " step" : " steps")
        color: Theme.dim
        font.pixelSize: Theme.type.tab.size
      }
      Label {
        visible: row.node.failed > 0
        text: " · " + row.node.failed + " failed"
        color: Theme.error
        font.pixelSize: Theme.type.tab.size
      }
      Item { Layout.fillWidth: true }
      Icon { name: row.expanded ? "chevron-down" : "chevron-right"; size: 12; color: Theme.dim }
    }
  }

  // The details: the agent's last words, the questions in full, the ways on.
  ColumnLayout {
    id: more
    visible: !row.full && row.expanded
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.space.gap }
    spacing: Theme.space.line

    Repeater {
      model: row.words
      delegate: Label {
        required property string modelData
        Layout.fillWidth: true
        text: modelData
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }
    Label {
      Layout.fillWidth: true
      visible: row.words.length === 0
      text: "Nothing said here yet."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }
    Repeater {
      model: row.asks
      delegate: Label {
        required property var modelData
        Layout.fillWidth: true
        text: "Asked " + (modelData.human ? "you" : modelData.to) + ": " + modelData.question
        color: modelData.human ? Theme.warning : Theme.foreground
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
      }
    }
    Flow {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      TraceButton { role: "action"; dense: true; text: "OPEN"; icon: "enter"; tip: "its thread, as a page"; onClicked: row.openThread(row.node.work) }
      TraceButton { role: "action"; dense: true; text: "LOG"; icon: "list"; tip: "the log kept to it"; onClicked: row.openLog(row.node.work) }
      TraceButton { role: "action"; dense: true; text: "MAP"; icon: "map"; tip: "the team's map, it picked"; onClicked: row.openMap(row.node.work) }
    }
  }

  FocusRing { visible: !row.full }
}
