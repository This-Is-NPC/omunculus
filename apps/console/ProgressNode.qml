pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/client/Progress.js" as Progress

// ProgressNode is one work of the chat's progress (ProgressTree): an open
// work (working, needs you, waiting, stopped, failed) is a framed card — its
// agent and state, its title, its stages, what it calls or does, a send-back
// with its reason, the questions it asked and its steps; a done, cancelled or
// coming work is one line. Picked, it shows its details instead of the
// questions' first lines: its agent's last words, its questions in full and
// the ways to its thread, log and team.
FocusScope {
  id: row

  // A node of Omunculus.progress.
  required property var node
  // On the path from the focus root to the active leaf.
  property bool active: false
  // At one end of the request picked elsewhere.
  property bool highlighted: false
  // Its details show.
  property bool expanded: false
  // It has works below it, folded away or not.
  property bool folds: false
  property bool folded: false

  signal toggled()
  signal foldToggled()
  signal openThread(string work)
  signal openLog(string work)
  signal openTeam(string work)

  readonly property bool quiet: ["done", "cancelled", "up-next"].includes(node.state)
  readonly property real now: Omunculus.tick
  readonly property color agentTone: Omunculus.toneOf(node.agent)
  readonly property var steps: node.steps
  readonly property var asks: node.asks
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

  readonly property string stageTip: {
    const lane = Omunculus.laneOf(Omunculus.work(node.work) || {})
    const at = steps.findIndex(step => step.status === "current")
    return lane && at >= 0 ? lane.name + " · stage " + (at + 1) + " of " + steps.length + ": " + steps[at].name : ""
  }

  implicitWidth: 240
  implicitHeight: (quiet ? line.implicitHeight + Theme.space.tight * 2 : card.implicitHeight + Theme.space.gap * 2)
    + (expanded ? more.implicitHeight + Theme.space.gap : 0)
  activeFocusOnTab: true
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
      row.forceActiveFocus()
      row.toggled()
    }
  }

  // The card's frame, or a wash over a one-line work.
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

  // A done, cancelled or coming work: one line.
  RowLayout {
    id: line
    visible: row.quiet
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
    visible: !row.quiet
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
    visible: row.expanded
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
      TraceButton { role: "action"; dense: true; text: "TEAM"; icon: "people"; tip: "the team page, it picked"; onClicked: row.openTeam(row.node.work) }
    }
  }

  FocusRing {}
}
