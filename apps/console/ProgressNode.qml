pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/client/Progress.js" as Progress

// ProgressNode is one work of a Progress tree. An open work (working, needs
// you, waiting, stopped, failed) is a framed card: its agent and state, its
// title, its stages, what it calls or does, a send-back with its reason, the
// questions it asked and its tool calls. A done, cancelled or coming work is
// one line. Picked, it shows its details: its agent's last words, its
// questions in full and the ways to its thread, log and map. "full" adds its
// team, the requests waiting between it and others, whether a work below it
// needs you, and its branch's totals.
FocusScope {
  id: row

  // A node of Omunculus.progress.
  required property var node
  property string mode: "compact"
  // On the path from the focus root to the active leaf.
  property bool active: false
  // At one end of the request picked elsewhere, as on the TEAM page.
  property bool highlighted: false
  property bool expanded: false
  // It has works below it, and they are folded away.
  property bool folds: false
  property bool folded: false

  signal toggled()
  signal foldToggled()
  signal openThread(string work)
  signal openLog(string work)
  signal openMap(string work)
  // A request badge, by request id ("full" only).
  signal requestPicked(string id)

  readonly property bool full: mode === "full"
  readonly property bool quiet: ["done", "cancelled", "up-next"].includes(node.state)
  readonly property real now: Omunculus.tick
  readonly property color agentTone: Omunculus.toneOf(node.agent)
  readonly property var steps: node.steps
  readonly property var asks: node.asks
  readonly property var asked: node.asked
  readonly property string clock: node.state === "working" && node.since !== null
    ? Progress.clock(Math.max(0, Math.round(now - node.since))) : ""

  // The state's icon, word and tone, as every progress view shows them.
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

  // A tally's money when the provider priced it, else its tokens.
  function spent(usage) {
    if (usage.calls === 0)
      return ""
    return usage.priced > 0 ? Omunculus.money(usage.cost) : Omunculus.tokens(usage.input + usage.output) + " tokens"
  }

  readonly property string branchLine: {
    const branch = node.branch
    const parts = [Progress.span(branch.seconds)]
    if (branch.agents > 1)
      parts.push(branch.agents + " agents")
    if (branch.calls > 0)
      parts.push(branch.calls + (branch.calls === 1 ? " call" : " calls"))
    const money = spent(branch.usage)
    if (money !== "")
      parts.push(money)
    return parts.join(" · ")
  }

  // Incoming requests, one badge per agent asking.
  readonly property var askedBy: {
    const by = {}
    for (const request of asked)
      (by[request.from] = by[request.from] || []).push(request)
    return Object.keys(by).map(from => ({ from: from, requests: by[from] }))
  }

  implicitWidth: 240
  implicitHeight: (quiet ? line.implicitHeight + 8 : card.implicitHeight + 16)
    + (expanded ? more.implicitHeight + 8 : 0)
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: node.agent + ", " + node.word + (node.title ? ", " + node.title : "")
  Keys.onReturnPressed: toggled()
  Keys.onSpacePressed: toggled()

  SurfaceFrame {
    id: frame
    anchors.fill: parent
    visible: !row.quiet || row.expanded || row.highlighted
    tone: row.highlighted ? Theme.warning : head.tone
    active: row.active || row.highlighted
    color: pointer.containsMouse ? Theme.highlight : fill
  }
  Rectangle {
    anchors.fill: parent
    visible: row.quiet && !frame.visible && pointer.containsMouse
    color: Theme.highlight
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { row.forceActiveFocus(); row.toggled() }
  }

  // A done, cancelled or coming work: one line.
  RowLayout {
    id: line
    visible: row.quiet
    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 8; rightMargin: 4; topMargin: 4 }
    spacing: 8
    StateMark { state: row.node.state; showWord: false }
    Label {
      Layout.maximumWidth: line.width * 0.4
      text: row.node.agent
      color: row.agentTone
      font.pixelSize: 12
      font.bold: true
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      readonly property string said: row.node.doing || row.node.word
      text: row.node.title + (said !== "" ? " · " + said.charAt(0).toLowerCase() + said.slice(1) : "")
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
    }
    Fold { visible: row.folds; folded: row.folded; onPressed: { row.forceActiveFocus(); row.foldToggled() } }
  }

  // The fold of the works below it.
  component Fold: Item {
    id: fold
    property bool folded: false
    signal pressed()
    Layout.preferredWidth: 24
    Layout.preferredHeight: 24
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
    visible: !row.quiet
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
    spacing: 3

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Portrait {
        Layout.preferredWidth: 20
        Layout.preferredHeight: 20
        agent: row.node.agent
        source: Omunculus.imageOf(row.node.agent)
        tone: row.agentTone
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.node.agent
        color: row.agentTone
        font.pixelSize: 12
        font.bold: true
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
      font.pixelSize: 12
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    Stepper {
      Layout.fillWidth: true
      steps: row.steps
      round: row.node.round
      tip: {
        const lane = Omunculus.laneOf(Omunculus.work(row.node.work) || {})
        const at = row.steps.findIndex(step => step.status === "current")
        return lane && at >= 0 ? lane.name + " · stage " + (at + 1) + " of " + row.steps.length + ": " + row.steps[at].name : ""
      }
    }

    // The tool it called last, else what it is doing.
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        visible: !!row.node.lastCall
        Layout.maximumWidth: card.width * 0.4
        text: row.node.lastCall ? row.node.lastCall.name : ""
        color: Theme.foreground
        font.pixelSize: 11
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: row.node.lastCall ? row.node.lastCall.brief : row.node.doing
        color: row.node.state === "failed" ? Theme.error : row.node.state === "stopped" || row.node.state === "needs-you" ? Theme.warning : Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }

    Label {
      Layout.fillWidth: true
      visible: row.node.round > 0
      text: "↩ Round " + row.node.round + (row.node.sentBack ? " · sent back by " + row.node.sentBack.by
        + (row.node.sentBack.why ? ": \"" + row.node.sentBack.why + "\"" : "") : "")
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }

    Repeater {
      model: row.asks
      delegate: RowLayout {
        id: ask
        required property var modelData
        Layout.fillWidth: true
        spacing: 8
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: "? asked " + (ask.modelData.human ? "you" : ask.modelData.to) + ": \"" + ask.modelData.question.split("\n")[0] + "\""
          color: ask.modelData.human ? Theme.warning : Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        Label { text: "waiting"; color: Theme.dim; font.pixelSize: 11 }
      }
    }

    // "full": the team, with whoever holds the stage ringed, and the requests.
    Flow {
      Layout.fillWidth: true
      visible: row.full && row.node.team.length > 0
      spacing: 4
      Repeater {
        model: row.full ? row.node.team : []
        delegate: Rectangle {
          id: member
          required property var modelData
          width: 20
          height: 20
          color: "transparent"
          border.color: modelData.current ? head.tone : "transparent"
          Portrait {
            anchors.centerIn: parent
            width: 16
            height: 16
            agent: member.modelData.agent
            source: Omunculus.imageOf(member.modelData.agent)
            tone: Omunculus.toneOf(member.modelData.agent)
          }
          HoverHandler { id: memberHover }
          Hint { active: memberHover.hovered; text: member.modelData.agent + (member.modelData.current ? " · has the stage" : "") }
        }
      }
    }
    Flow {
      Layout.fillWidth: true
      visible: row.full && (row.asks.length > 0 || row.askedBy.length > 0 || row.node.below !== "")
      spacing: 6
      // A work below waits on you; this one keeps its own state.
      Chip {
        visible: row.full && row.node.below !== ""
        text: "⇣ needs you below"
        accent: Theme.warning
        onClicked: row.requestPicked(row.node.below)
      }
      Repeater {
        model: row.full ? row.asks : []
        delegate: Chip {
          required property var modelData
          text: "⇡ waiting for " + (modelData.human ? "you" : modelData.to)
          accent: modelData.human ? Theme.warning : Theme.primary
          checked: modelData.human
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
    }
    Label {
      Layout.fillWidth: true
      visible: row.full && row.branchLine !== ""
      text: row.branchLine
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
    }

    RowLayout {
      Layout.fillWidth: true
      visible: row.node.calls > 0
      spacing: 0
      Label {
        text: row.node.calls + (row.node.calls === 1 ? " tool call" : " tool calls")
        color: Theme.dim
        font.pixelSize: 11
      }
      Label {
        visible: row.node.failed > 0
        text: " · " + row.node.failed + " failed"
        color: Theme.error
        font.pixelSize: 11
      }
      Item { Layout.fillWidth: true }
      Icon { name: row.expanded ? "chevron-down" : "chevron-right"; size: 12; color: Theme.dim }
    }
  }

  // The details: the agent's last words, the questions in full, the ways on.
  ColumnLayout {
    id: more
    visible: row.expanded
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 8 }
    spacing: 4

    Repeater {
      model: row.words
      delegate: Label {
        required property string modelData
        Layout.fillWidth: true
        text: modelData
        color: Theme.foreground
        font.pixelSize: 12
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
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }
    Repeater {
      model: row.asks
      delegate: Label {
        required property var modelData
        Layout.fillWidth: true
        text: "Asked " + (modelData.human ? "you" : modelData.to) + ": " + modelData.question
        color: modelData.human ? Theme.warning : Theme.foreground
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }
    Flow {
      Layout.fillWidth: true
      spacing: 6
      TraceButton { role: "action"; dense: true; text: "OPEN"; icon: "enter"; onClicked: row.openThread(row.node.work) }
      TraceButton { role: "action"; dense: true; text: "LOG"; icon: "list"; onClicked: row.openLog(row.node.work) }
      TraceButton { role: "action"; dense: true; text: "MAP"; icon: "map"; onClicked: row.openMap(row.node.work) }
    }
  }

  FocusRing {}
}
