pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Time.js" as Time
import "kit/ui"

// WorkRuns is the runs of the work picked on the map, newest first, one line
// each: the local time it started, its agent, how it ended (or that it still
// runs, or stopped without end) and how long it took, read from what the runs
// command sums up, matched to the work's own by id. The calls, the failures
// and what the model used are behind DETAIL, which shows the run call by
// call; Esc goes back to the list. Above them, the work's runs in all, the
// calls that failed and what they cost.
Item {
  id: runsPane

  // The work, or "" for the root agent's own conversation.
  required property string key
  // The run opened call by call, or "".
  property string opened: ""
  signal promptWanted(string run)

  // The work's runs in the conversation's snapshot, newest first.
  readonly property var own: Omunculus.runs
    .filter(run => (run.work_id || "") === key)
    .sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)))
  // Which of them have closed, to read them again when one does.
  readonly property string closed: own.filter(run => run.status !== "open").map(run => run.id).join(" ")

  // Run id -> the lines the runs command printed under it.
  property var summaries: ({})
  property string failure: ""
  property bool loading: false
  property string detail: ""
  property string detailFailure: ""
  // The answer awaited; an older one that comes late is dropped.
  property int asked: 0

  function load() {
    const token = ++asked
    loading = true
    Omunculus.command("runs", {}, output => {
      if (token !== asked)
        return
      loading = false
      failure = ""
      summaries = parse(output)
    }, reason => {
      if (token !== asked)
        return
      loading = false
      failure = reason
    })
  }

  // The summaries the runs command printed, a block each, by run id.
  function parse(output) {
    const found = {}
    for (const block of output.split("\n\n")) {
      const lines = block.split("\n")
      const head = /^run (\S+) · /.exec(lines[0])
      if (head)
        found[head[1]] = lines.slice(1).map(line => line.trim())
    }
    return found
  }

  function open(id) {
    opened = id
    // Esc, from wherever the run was opened, goes back to the list.
    forceActiveFocus()
    detail = ""
    detailFailure = ""
    if (own.some(run => run.id === id && run.status === "open"))
      return
    const token = ++asked
    Omunculus.command("runs", { run: id }, output => {
      if (token === asked)
        detail = output
    }, reason => {
      if (token === asked)
        detailFailure = reason
    })
  }

  function back() {
    opened = ""
    Qt.callLater(() => list.forceActiveFocus())
  }

  // The summed up runs: how many, the calls that failed, what they cost.
  readonly property var totals: {
    let failed = 0
    let cost = 0
    let priced = false
    for (const run of own) {
      for (const line of summaries[run.id] || []) {
        if (line.startsWith("failed:"))
          failed++
        const spent = line.startsWith("model:") ? /\$([0-9.]+)/.exec(line) : null
        if (spent) {
          cost += Number(spent[1])
          priced = true
        }
      }
    }
    return { failed: failed, cost: cost, priced: priced }
  }

  function seconds(run) {
    if (!run.started_at || !run.finished_at)
      return ""
    return Math.max(0, Math.round((Date.parse(run.finished_at) - Date.parse(run.started_at)) / 1000)) + " S"
  }

  onVisibleChanged: if (visible) load()
  onKeyChanged: {
    opened = ""
    summaries = {}
    if (visible)
      load()
  }
  onClosedChanged: if (visible) load()

  Keys.onEscapePressed: event => {
    if (opened === "") {
      event.accepted = false
      return
    }
    back()
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.gap
    visible: runsPane.opened === ""

    Label {
      Layout.fillWidth: true
      text: runsPane.own.length + (runsPane.own.length === 1 ? " RUN" : " RUNS")
        + "  ·  " + runsPane.totals.failed + (runsPane.totals.failed === 1 ? " FAILED CALL" : " FAILED CALLS")
        + (runsPane.totals.priced ? "  ·  " + Omunculus.money(runsPane.totals.cost) : "")
      color: runsPane.totals.failed > 0 ? Theme.error : Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 2
      elide: Text.ElideRight
    }

    Label {
      Layout.fillWidth: true
      visible: runsPane.failure !== "" || runsPane.loading && Object.keys(runsPane.summaries).length === 0 || runsPane.own.length === 0
      text: runsPane.failure !== "" ? runsPane.failure
        : runsPane.own.length === 0 ? "NO RUN OF THIS WORK YET"
        : "READING THE RUNS"
      color: runsPane.failure !== "" ? Theme.error : Theme.dim
      font.pixelSize: runsPane.failure !== "" ? 11 : 10
      font.letterSpacing: runsPane.failure !== "" ? 0 : 2
      wrapMode: Text.Wrap
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      spacing: Theme.space.row
      boundsBehavior: Flickable.StopAtBounds
      keyNavigationEnabled: true
      activeFocusOnTab: true
      model: runsPane.own
      highlightFollowsCurrentItem: false
      Keys.onReturnPressed: if (currentItem) runsPane.open(runsPane.own[currentIndex].id)
      Keys.onSpacePressed: if (currentItem) runsPane.open(runsPane.own[currentIndex].id)

      delegate: Rectangle {
        id: card
        required property var modelData
        required property int index
        readonly property var outcome: Progress.outcome(modelData.status, runsPane.summaries[modelData.id] || [])
        readonly property bool current: list.activeFocus && list.currentIndex === index
        width: ListView.view.width
        implicitHeight: facts.implicitHeight + Theme.space.insetTop * 2
        color: current ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
        border.color: Theme.line

        RowLayout {
          id: facts
          anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
          spacing: Theme.space.gap
          Label {
            text: Time.clock(card.modelData.started_at, Date.now())
            color: Theme.dim
            font.pixelSize: 10
          }
          Label {
            text: String(card.modelData.agent).toUpperCase()
            color: Omunculus.toneOf(card.modelData.agent)
            font.pixelSize: 10
            font.letterSpacing: 2
          }
          StateMark {
            Layout.fillWidth: true
            state: card.outcome.state
            text: card.outcome.text + (card.modelData.status === "open" ? "" : runsPane.seconds(card.modelData) !== "" ? Theme.type.meta.separator + runsPane.seconds(card.modelData) : "")
          }
          Label {
            text: "DETAIL"
            color: card.current || pointer.containsMouse ? Theme.primary : Theme.dim
            font.pixelSize: 10
            font.letterSpacing: 2
          }
          Icon { name: "chevron-right"; size: 12; color: card.current || pointer.containsMouse ? Theme.primary : Theme.dim }
        }

        MouseArea {
          id: pointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            list.currentIndex = card.index
            runsPane.open(card.modelData.id)
          }
        }
      }
    }
  }

  // The run opened, call by call.
  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.gap
    visible: runsPane.opened !== ""

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      IconButton { name: "chevron-left"; tip: "back to the runs  esc"; onClicked: runsPane.back() }
      Label {
        Layout.fillWidth: true
        text: "RUN " + runsPane.opened.slice(0, 8).toUpperCase()
        color: Theme.primary
        font.pixelSize: 10
        font.letterSpacing: 2
        elide: Text.ElideRight
      }
      TraceButton {
        dense: true
        role: "action"
        text: "PROMPT"
        tip: "the prompt this run was given"
        onClicked: runsPane.promptWanted(runsPane.opened)
      }
      IconButton { name: "copy"; tip: "copy the run"; visible: runsPane.detail !== ""; onClicked: Omunculus.copy(runsPane.detail) }
    }

    Label {
      Layout.fillWidth: true
      visible: runsPane.detail === ""
      text: runsPane.detailFailure !== "" ? runsPane.detailFailure
        : runsPane.own.some(run => run.id === runsPane.opened && run.status === "open") ? "STILL RUNNING; ITS CALLS SHOW ONCE IT CLOSES"
        : "READING THE RUN"
      color: runsPane.detailFailure !== "" ? Theme.error : Theme.dim
      font.pixelSize: runsPane.detailFailure !== "" ? 11 : 10
      font.letterSpacing: runsPane.detailFailure !== "" ? 0 : 2
      wrapMode: Text.Wrap
    }

    TextPane {
      id: calls
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: runsPane.detail !== ""
      text: runsPane.detail
      tone: line => /^\d+\. model:/.test(line) ? Theme.secondary
        : / → failed: /.test(line) ? Theme.error
        : /^run /.test(line) ? Theme.dim
        : Theme.foreground
    }

    Item { Layout.fillHeight: true; visible: runsPane.detail === "" }
  }
}
