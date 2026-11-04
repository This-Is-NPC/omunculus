pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// NodeDetail is one work of the TEAM page in full: its agent, title, way
// down and stages on top, then tabs. OVERVIEW: what it does now and did
// last, a send-back or a stop and why, whom it waits on and who asks it,
// its team, each stage's time, its branch's time, calls and cost, and the
// work itself — goal, workspace, where it came from, what it asked and the
// notes it left you. THREAD: what its agents said and did, and a composer to
// write to its agent or leave it a note. REQUESTS: what it asked and what it
// is asked, each with the way it climbed, to answer in place. CHANGES: the
// files it changed. RUNS: its runs, and the prompt each was given. LOG: the
// log kept to its events. `[` and `]` move between the tabs.
FocusScope {
  id: pane

  // The work, and its Progress node (null while the progress is not known).
  required property string key
  property var node: null
  // The way down to it, outermost first: [{text}].
  property var trail: []
  // Whether it has a way back to the outline (a page over it).
  property bool closable: false
  // Whether the map can show it.
  property bool mappable: false
  signal closed()
  signal crumbChosen(int index)
  signal picked(string key)
  signal openLog(string work)
  signal openMap(string work)

  readonly property var tabs: [
    { name: "overview", tip: "what it does, whom it waits on, its team, time and cost" },
    { name: "thread", tip: "what its agents said and did; write to it" },
    { name: "requests", tip: "what it asked and what it is asked" },
    { name: "changes", tip: "the files it changed" },
    { name: "runs", tip: "its runs, and the prompt each was given" },
    { name: "log", tip: "the log kept to its events" }
  ]
  property string tab: "overview"
  // The run whose prompt shows on RUNS, or "" for the list.
  property string promptRun: ""
  property bool prompting: false
  onKeyChanged: {
    promptRun = ""
    prompting = false
  }

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property string agent: node ? node.agent : work ? Omunculus.agentOf(work) : ""
  readonly property color agentTone: Omunculus.toneOf(agent)
  readonly property var asks: node ? node.asks : []
  readonly property var asked: node ? node.asked : []
  readonly property var steps: node ? node.steps : []
  readonly property real now: Omunculus.tick
  readonly property string clock: node && node.state === "working" && node.since !== null
    ? Progress.clock(Math.max(0, Math.round(now - node.since))) : ""

  // The tab `step` places away, wrapping.
  function cycle(step) {
    const at = tabs.findIndex(each => each.name === tab)
    tab = tabs[(at + step + tabs.length) % tabs.length].name
  }
  function show(name) { tab = name }
  function focusTabs() { tabBar.forceActiveFocus() }

  // Shows its thread and puts the keyboard in the composer, to write to its
  // agent or, `noting`, to leave it a note.
  function write(noting) {
    tab = "thread"
    Qt.callLater(() => composer.focusEntry(noting))
  }

  // A tally's money when the provider priced it, with its tokens.
  function cost(usage) {
    if (usage.calls === 0)
      return ""
    return (usage.priced > 0 ? Omunculus.money(usage.cost) + " · " : "")
      + Omunculus.tokens(usage.input) + " read · " + Omunculus.tokens(usage.output) + " written"
  }

  // A branch or work's time, agents and calls, as one line.
  function totals(tally) {
    const parts = [Progress.span(tally.seconds)]
    if (tally.agents > 1)
      parts.push(tally.agents + " agents")
    if (tally.works > 1)
      parts.push(tally.works + " works")
    if (tally.calls > 0)
      parts.push(tally.calls + (tally.calls === 1 ? " call" : " calls"))
    if (tally.failed > 0)
      parts.push(tally.failed + " failed")
    return parts.join(" · ")
  }

  // How long ago a time in seconds was, in words.
  function ago(at) {
    return typeof at === "number" ? Progress.span(Math.max(0, Math.round(now - at))) + " ago" : ""
  }

  Keys.onPressed: event => {
    if (!Typing.idle || (event.text !== "[" && event.text !== "]"))
      return
    cycle(event.text === "]" ? 1 : -1)
    event.accepted = true
  }

  // A fact of OVERVIEW: its name beside what it is, or above it when narrow.
  component Fact: GridLayout {
    id: fact
    property string name
    default property alias body: value.data
    Layout.fillWidth: true
    columns: width < 360 ? 1 : 2
    columnSpacing: 12
    rowSpacing: 2
    Label {
      Layout.preferredWidth: fact.columns === 1 ? -1 : 80
      Layout.alignment: Qt.AlignTop
      text: fact.name
      color: Theme.dim
      font.pixelSize: 11
      elide: Text.ElideRight
    }
    ColumnLayout {
      id: value
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      spacing: 2
    }
  }
  component Value: Label {
    Layout.fillWidth: true
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    // Who and what, the way down, the stages.
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      IconButton {
        visible: pane.closable
        Layout.alignment: Qt.AlignTop
        name: "chevron-left"
        tip: "back to the outline  Esc"
        onClicked: pane.closed()
      }
      Portrait {
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        agent: pane.agent
        source: Omunculus.imageOf(pane.agent)
        tone: pane.agentTone
        framed: true
      }
      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: 2
        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Label {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: pane.agent
            color: pane.agentTone
            font.pixelSize: 12
            font.bold: true
            elide: Text.ElideRight
          }
          StateMark {
            visible: pane.node !== null
            Layout.maximumWidth: 160
            state: pane.node ? pane.node.state : ""
            clock: pane.clock
          }
        }
        Label {
          Layout.fillWidth: true
          text: pane.node ? pane.node.title : pane.work ? pane.work.title : ""
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }
    }
    Breadcrumb {
      Layout.fillWidth: true
      trail: pane.trail
      onChosen: index => pane.crumbChosen(index)
    }
    Stepper {
      Layout.fillWidth: true
      steps: pane.steps
      round: pane.node ? pane.node.round : 0
      tip: pane.work && pane.work.workflow ? pane.work.workflow : ""
    }

    // The tabs; REQUESTS counts what waits.
    Flow {
      id: tabBar
      Layout.fillWidth: true
      spacing: 6
      activeFocusOnTab: true
      Keys.onLeftPressed: pane.cycle(-1)
      Keys.onRightPressed: pane.cycle(1)
      FocusRing {}
      Repeater {
        model: pane.tabs
        delegate: TraceButton {
          required property var modelData
          dense: true
          role: pane.tab === modelData.name ? "primary" : "action"
          text: modelData.name.toUpperCase()
            + (modelData.name === "requests" && pane.asks.length + pane.asked.length > 0 ? " " + (pane.asks.length + pane.asked.length) : "")
          tip: modelData.tip
          onClicked: pane.tab = modelData.name
        }
      }
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

    // OVERVIEW.
    ScrollPage {
      id: overview
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "overview"
      contentHeight: facts.implicitHeight

      ColumnLayout {
        id: facts
        width: overview.width
        spacing: 8

        Fact {
          name: "Now"
          visible: pane.node !== null && pane.node.state !== "done" && pane.node.state !== "cancelled"
          RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label {
              visible: !!(pane.node && pane.node.lastCall)
              Layout.maximumWidth: implicitWidth
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: pane.node && pane.node.lastCall ? pane.node.lastCall.name : ""
              font.pixelSize: 12
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: pane.node ? (pane.node.lastCall ? pane.node.lastCall.brief : pane.node.doing) : ""
              color: Theme.dim
              font.pixelSize: 12
              elide: Text.ElideRight
            }
            Label { visible: pane.clock !== ""; text: pane.clock; color: Theme.dim; font.pixelSize: 11 }
          }
        }
        Fact {
          name: "Last"
          visible: !!(pane.node && pane.node.last)
          Value {
            text: pane.node && pane.node.last ? pane.node.last.text + (pane.ago(pane.node.last.at) ? " · " + pane.ago(pane.node.last.at) : "") : ""
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }
        Fact {
          name: "Round " + (pane.node ? pane.node.round : "")
          visible: !!(pane.node && pane.node.round > 0)
          Value {
            text: pane.node && pane.node.sentBack ? "↩ sent back by " + pane.node.sentBack.by
              + (pane.node.sentBack.why ? ": \"" + pane.node.sentBack.why + "\"" : "") : "↩ sent back"
          }
        }
        Fact {
          name: "Stopped"
          visible: !!(pane.node && pane.node.stopped)
          Value {
            text: pane.node && pane.node.stopped ? "by " + pane.node.stopped.by + (pane.node.stopped.why ? ": " + pane.node.stopped.why : "") : ""
            color: Theme.warning
          }
        }
        Fact {
          name: "Waits on"
          Repeater {
            model: pane.asks
            delegate: Value {
              required property var modelData
              text: "⇡ " + modelData.chain.join(" › ")
              color: modelData.human ? Theme.warning : Theme.foreground
            }
          }
          Value {
            visible: pane.asks.length === 0
            text: pane.node && pane.node.waitingOn ? pane.node.waitingOn : "nobody"
            color: Theme.dim
          }
        }
        Fact {
          name: "Asked by"
          Value {
            text: {
              const by = {}
              for (const request of pane.asked)
                by[request.from] = (by[request.from] || 0) + 1
              const names = Object.keys(by).map(name => name + " (" + by[name] + " open)")
              return names.length > 0 ? "⇣ " + names.join(", ") : "nobody"
            }
            color: pane.asked.length > 0 ? Theme.foreground : Theme.dim
          }
        }
        Fact {
          name: "Team"
          visible: !!pane.node && pane.node.team.length > 0
          Flow {
            Layout.fillWidth: true
            spacing: 10
            Repeater {
              model: pane.node ? pane.node.team : []
              delegate: Row {
                id: member
                required property var modelData
                spacing: 4
                Rectangle {
                  width: 20
                  height: 20
                  color: "transparent"
                  border.color: member.modelData.current ? Omunculus.toneOf(member.modelData.agent) : "transparent"
                  Portrait {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    agent: member.modelData.agent
                    source: Omunculus.imageOf(member.modelData.agent)
                    tone: Omunculus.toneOf(member.modelData.agent)
                  }
                }
                Label {
                  anchors.verticalCenter: parent.verticalCenter
                  text: member.modelData.agent
                  color: member.modelData.current ? Omunculus.toneOf(member.modelData.agent) : Theme.dim
                  font.pixelSize: 11
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, Math.max(0, facts.width - 130))
                }
              }
            }
          }
        }
        Fact {
          name: "Stages"
          visible: pane.steps.length > 0
          Repeater {
            model: pane.steps
            delegate: RowLayout {
              id: stage
              required property var modelData
              readonly property bool current: modelData.status === "current"
              Layout.fillWidth: true
              spacing: 8
              Label {
                text: stage.modelData.status === "done" ? "✓" : stage.current ? "●" : "○"
                color: stage.modelData.status === "done" ? Theme.success : stage.current ? Theme.primary : Theme.dim
                font.pixelSize: 12
              }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: stage.modelData.name + (stage.current && pane.node.round > 0 ? " · round " + pane.node.round : "")
                color: stage.current ? Theme.primary : stage.modelData.status === "done" ? Theme.foreground : Theme.dim
                font.pixelSize: 12
                font.bold: stage.current
                elide: Text.ElideRight
              }
              Label {
                Layout.maximumWidth: stage.width * 0.5
                text: stage.modelData.agent + (stage.modelData.seconds > 0 ? " · " + Progress.span(Math.round(stage.modelData.seconds)) + (stage.current ? " so far" : "") : "")
                color: Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
            }
          }
        }
        Fact {
          name: "This work"
          visible: pane.node !== null
          Value { text: pane.node ? pane.totals(pane.node.own) : ""; color: Theme.dim }
        }
        Fact {
          name: "Branch"
          visible: !!pane.node && pane.node.branch.works > 1
          Value { text: pane.node ? pane.totals(pane.node.branch) : ""; color: Theme.dim }
        }
        Fact {
          name: "Cost"
          visible: spent.text !== ""
          Value { id: spent; text: pane.node ? pane.cost(pane.node.branch.usage) : ""; color: Theme.dim }
        }

        Flow {
          Layout.fillWidth: true
          Layout.topMargin: 4
          spacing: 6
          TraceButton { role: "action"; dense: true; icon: "enter"; text: "OPEN THREAD"; tip: "what its agents said and did"; onClicked: pane.tab = "thread" }
          TraceButton { role: "action"; dense: true; icon: "list"; text: "SHOW IN LOG"; tip: "the log page, kept to its events"; onClicked: pane.openLog(pane.key) }
          TraceButton {
            visible: pane.mappable
            role: "action"
            dense: true
            icon: "map"
            text: "SHOW ON MAP"
            tip: "the team's map, this work picked"
            onClicked: pane.openMap(pane.key)
          }
        }

        Kicker { Layout.fillWidth: true; Layout.topMargin: 6; text: "the work" }
        WorkSummary {
          Layout.fillWidth: true
          key: pane.key
          onPicked: key => pane.picked(key)
        }
      }
    }

    // THREAD.
    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "thread"
      spacing: 10
      TimelineView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        thread: Omunculus.threadOf(pane.key)
        emptyText: "NOTHING SAID HERE YET"
        requestsShown: false
        onOpenWork: work => pane.picked(work)
      }
      Composer {
        id: composer
        Layout.fillWidth: true
        compact: true
        work: pane.key
      }
    }

    // REQUESTS.
    ScrollPage {
      id: requestsPage
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "requests"
      contentHeight: requestList.implicitHeight

      ColumnLayout {
        id: requestList
        width: requestsPage.width
        spacing: 10

        Kicker { Layout.fillWidth: true; text: "it asked"; visible: pane.asks.length > 0 }
        Repeater {
          model: pane.asks
          delegate: ColumnLayout {
            id: ask
            required property var modelData
            Layout.fillWidth: true
            spacing: 4
            Label {
              Layout.fillWidth: true
              text: "⇡ " + (ask.modelData.chain && ask.modelData.chain.length > 0 ? ask.modelData.chain.join(" › ") : ask.modelData.to)
                + " · " + (ask.modelData.human ? "you decide" : ask.modelData.to + " decides")
              color: Theme.dim
              font.pixelSize: 11
              wrapMode: Text.Wrap
            }
            RequestDecision { Layout.fillWidth: true; key: ask.modelData.id }
          }
        }
        Kicker { Layout.fillWidth: true; text: "it is asked"; visible: pane.asked.length > 0 }
        Repeater {
          model: pane.asked
          delegate: ColumnLayout {
            id: incoming
            required property var modelData
            Layout.fillWidth: true
            spacing: 4
            RowLayout {
              Layout.fillWidth: true
              spacing: 8
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "⇣ from " + incoming.modelData.from + " · " + pane.agent + " decides, or you instead"
                color: Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Chip {
                visible: incoming.modelData.fromWork !== pane.key
                text: "ITS WORK"
                tip: "the work that asked"
                onClicked: pane.picked(incoming.modelData.fromWork)
              }
            }
            RequestDecision { Layout.fillWidth: true; key: incoming.modelData.id }
          }
        }
        Label {
          Layout.fillWidth: true
          visible: pane.asks.length === 0 && pane.asked.length === 0
          text: "Nothing waits between it and anyone."
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
    }

    // CHANGES.
    WorkChanges {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "changes"
      key: pane.key
    }

    // RUNS, and the prompt of one.
    WorkRuns {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "runs" && !pane.prompting
      key: pane.key
      onPromptWanted: run => {
        pane.promptRun = run
        pane.prompting = true
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "runs" && pane.prompting
      spacing: 8
      Chip { text: "‹ RUNS"; tip: "back to its runs"; onClicked: pane.prompting = false }
      WorkPrompt {
        Layout.fillWidth: true
        Layout.fillHeight: true
        key: pane.key
        run: pane.promptRun
        onLatestWanted: pane.promptRun = ""
      }
    }

    // LOG, loaded while shown.
    Loader {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: pane.tab === "log"
      active: visible
      sourceComponent: LogView {
        filter: pane.key
        onLeave: pane.tab = "overview"
      }
    }
  }
}
