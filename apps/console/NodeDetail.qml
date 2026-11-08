pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// NodeDetail is one work of the TEAM page in full. A header strip says its
// agent, title, round and state, with its action at the right — ANSWER, in
// the warning tone, while it or a work below it waits on you, else OPEN
// THREAD — then LOG and, behind "more", ESCALATE and MARK READ. Under
// it are its way down (Breadcrumb), its stages and the tabs. OVERVIEW: what
// it does now and did last, a send-back or a stop and why, whom it waits on
// and who asks it, its team, each stage's time, its branch's time, calls and
// cost, and the work itself — goal, workspace, where it came from, what it
// asked and the notes it left you. THREAD: what its agents said and did, and
// a composer to write to its agent or leave it a note. REQUESTS: what it
// asked and what it is asked, each with the way it climbed, to answer in
// place. CHANGES: the files it changed. RUNS: its runs, and the prompt each
// was given. LOG: the log kept to its events. `[` and `]`, or ←/→ on the
// tabs, move between them.
FocusScope {
  id: pane

  // The work, and its Progress node (null while the progress is not known).
  required property string key
  property var node: null
  // The way down to it, outermost first: [{text}].
  property var trail: []
  // Whether it has a way back to the tree (a page over it).
  property bool closable: false
  signal closed()
  signal crumbChosen(int index)
  signal picked(string key)
  signal openLog(string work)
  // A request's decision, over the page: to answer it or, `escalating`, to
  // raise it.
  signal decide(string id, bool escalating)

  readonly property var tabs: ["overview", "thread", "requests", "changes", "runs", "log"]
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
  // What waits on you: its own question, else one below it.
  readonly property var askedOfYou: asks.filter(ask => ask.human)
  readonly property string answering: askedOfYou.length > 0 ? askedOfYou[0].id : node ? node.below : ""
  readonly property var notes: key !== "" ? Omunculus.unreadFrom(key) : []
  readonly property real now: Omunculus.tick
  readonly property string clock: node && node.state === "working" && node.since !== null
    ? Progress.clock(Math.max(0, Math.round(now - node.since))) : ""
  // Its strip's action shows its icon alone.
  readonly property bool tight: Breakpoints.tight(width)

  // The tab `step` places away, wrapping; `focusing`, the keyboard follows.
  function cycle(step, focusing) {
    const at = tabs.indexOf(tab)
    tab = tabs[(at + step + tabs.length) % tabs.length]
    if (focusing)
      tabsLater.restart()
  }
  function show(name) { tab = name }
  function focusTabs() {
    const item = tabRow.itemAt(tabs.indexOf(tab))
    if (item)
      item.forceActiveFocus()
  }

  // Shows its thread and puts the keyboard in the composer, to write to its
  // agent or, `noting`, to leave it a note.
  function write(noting) {
    tab = "thread"
    composerLater.noting = noting
    composerLater.restart()
  }

  // Once the tab shows; timers go with the pane, never running on what is gone.
  Timer { id: tabsLater; interval: 0; onTriggered: pane.focusTabs() }
  Timer { id: composerLater; property bool noting; interval: 0; onTriggered: composer.focusEntry(noting) }

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
    cycle(event.text === "]" ? 1 : -1, false)
    event.accepted = true
  }

  // A fact of OVERVIEW: its name beside what it is, or above it when narrow.
  component Fact: GridLayout {
    id: fact
    property string name
    default property alias body: value.data
    Layout.fillWidth: true
    columns: width < 360 ? 1 : 2
    columnSpacing: Theme.space.cell
    rowSpacing: Theme.space.row
    Label {
      Layout.preferredWidth: fact.columns === 1 ? -1 : 80
      Layout.alignment: Qt.AlignTop
      text: fact.name
      color: Theme.dim
      font.pixelSize: Theme.type.tab.size
      elide: Text.ElideRight
    }
    ColumnLayout {
      id: value
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      spacing: Theme.space.row
    }
  }
  component Value: Label {
    Layout.fillWidth: true
    font.pixelSize: Theme.type.body.size
    wrapMode: Text.Wrap
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    // The header strip: who and what, and what to do with it.
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: Theme.size.strip
      color: "transparent"
      border.color: Theme.line

      RowLayout {
        anchors { fill: parent; leftMargin: pane.closable ? Theme.space.trail : Theme.space.inset; rightMargin: Theme.space.trail }
        spacing: Theme.space.gap
        IconButton {
          visible: pane.closable
          name: "chevron-left"
          tip: "back to the tree  Esc"
          onClicked: pane.closed()
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: [
            pane.agent,
            pane.node ? pane.node.title : pane.work ? pane.work.title : "",
            pane.node && pane.node.round > 0 ? "round " + pane.node.round : "",
            pane.node ? Progress.word(pane.node.state) + (pane.clock !== "" ? " " + pane.clock : "") : ""
          ].filter(part => part).join(Theme.type.meta.separator).toUpperCase()
          color: Theme.dim
          font.pixelSize: Theme.type.meta.size
          font.letterSpacing: Theme.type.meta.tracking
          elide: Text.ElideRight
        }
        // Urgent, never the main: its tone says so.
        TraceButton {
          dense: true
          role: "progress"
          tone: pane.answering !== "" ? Theme.warning : Theme.primary
          icon: pane.answering !== "" ? "enter" : "send"
          text: pane.tight ? "" : pane.answering !== "" ? "ANSWER" : "OPEN THREAD"
          Layout.preferredWidth: pane.tight ? Breakpoints.target(Window.width) : -1
          tip: pane.answering !== "" ? (pane.askedOfYou.length > 0 ? "answer what it asked you" : "answer what a work below it asked you")
            : "what its agents said and did"
          onClicked: pane.answering !== "" ? pane.decide(pane.answering, false) : pane.show("thread")
        }
        IconButton { name: "list"; tip: "the log page, kept to its events"; onClicked: pane.openLog(pane.key) }
        ActionMenu {
          readonly property var entries: [
            { id: "escalate", icon: "chevron-up", text: "ESCALATE", shown: pane.askedOfYou.length > 0 },
            { id: "read", icon: "check", text: pane.notes.length > 1 ? "MARK " + pane.notes.length + " NOTES READ" : "MARK READ", shown: pane.notes.length > 0 }
          ]
          visible: items.length > 0
          items: entries.filter(entry => entry.shown)
          tip: "more on this work"
          onChosen: id => {
            if (id === "escalate")
              pane.decide(pane.askedOfYou[0].id, true)
            else
              pane.notes.forEach(note => Omunculus.markRead(note.id))
          }
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

    // The tabs; REQUESTS counts what waits, and is marked while you are asked.
    Flow {
      Layout.fillWidth: true
      spacing: Theme.space.section
      Repeater {
        id: tabRow
        model: pane.tabs
        delegate: Tab {
          required property string modelData
          required property int index
          readonly property int waiting: modelData === "requests" ? pane.asks.length + pane.asked.length : 0
          label: modelData + (waiting > 0 ? " " + waiting : "")
          digit: String(index + 1).padStart(2, "0")
          current: pane.tab === modelData
          alert: modelData === "requests" && pane.askedOfYou.length > 0
          onChosen: pane.tab = modelData
          Keys.onLeftPressed: pane.cycle(-1, true)
          Keys.onRightPressed: pane.cycle(1, true)
        }
      }
    }

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
        spacing: Theme.space.tight

        Fact {
          name: "Now"
          visible: pane.node !== null && !Progress.closed(pane.node.state)
          RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.tight
            Label {
              visible: !!(pane.node && pane.node.lastCall)
              Layout.maximumWidth: implicitWidth
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: pane.node && pane.node.lastCall ? pane.node.lastCall.name : ""
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: pane.node ? (pane.node.lastCall ? pane.node.lastCall.brief : pane.node.doing) : ""
              color: Theme.dim
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            Label { visible: pane.clock !== ""; text: pane.clock; color: Theme.dim; font.pixelSize: Theme.type.tab.size }
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
        // Each portrait beside its agent's name, the one with the stage ringed.
        Fact {
          name: "Team"
          visible: !!pane.node && pane.node.team.length > 0
          Flow {
            Layout.fillWidth: true
            spacing: Theme.space.gap
            Repeater {
              model: pane.node ? pane.node.team : []
              delegate: Row {
                id: member
                required property var modelData
                spacing: Theme.space.line
                Rectangle {
                  width: 20
                  height: width
                  color: "transparent"
                  border.color: member.modelData.current ? Omunculus.toneOf(member.modelData.agent) : "transparent"
                  Portrait {
                    anchors.centerIn: parent
                    width: 16
                    height: width
                    agent: member.modelData.agent
                    source: Omunculus.imageOf(member.modelData.agent)
                    tone: Omunculus.toneOf(member.modelData.agent)
                  }
                }
                Label {
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  text: member.modelData.agent
                  color: member.modelData.current ? Omunculus.toneOf(member.modelData.agent) : Theme.dim
                  font.pixelSize: Theme.type.tab.size
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
              spacing: Theme.space.tight
              Label {
                text: stage.modelData.status === "done" ? "✓" : stage.current ? "●" : "○"
                color: stage.modelData.status === "done" ? Theme.success : stage.current ? Theme.primary : Theme.dim
                font.pixelSize: Theme.type.body.size
              }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: stage.modelData.name + (stage.current && pane.node.round > 0 ? " · round " + pane.node.round : "")
                color: stage.current ? Theme.primary : stage.modelData.status === "done" ? Theme.foreground : Theme.dim
                font.pixelSize: Theme.type.body.size
                font.bold: stage.current
                elide: Text.ElideRight
              }
              Label {
                Layout.maximumWidth: facts.width * 0.4
                text: stage.modelData.agent + (stage.modelData.seconds > 0 ? " · " + Progress.span(Math.round(stage.modelData.seconds)) + (stage.current ? " so far" : "") : "")
                color: Theme.dim
                font.pixelSize: Theme.type.tab.size
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

        Kicker { Layout.fillWidth: true; Layout.topMargin: Theme.space.tight; text: "the work" }
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
      spacing: Theme.space.gap
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
        spacing: Theme.space.gap

        Kicker { Layout.fillWidth: true; text: "it asked"; visible: pane.asks.length > 0 }
        Repeater {
          model: pane.asks
          delegate: ColumnLayout {
            id: ask
            required property var modelData
            Layout.fillWidth: true
            spacing: Theme.space.line
            Label {
              Layout.fillWidth: true
              text: "⇡ " + (ask.modelData.chain && ask.modelData.chain.length > 0 ? ask.modelData.chain.join(" › ") : ask.modelData.to)
                + " · " + (ask.modelData.human ? "you decide" : ask.modelData.to + " decides")
              color: Theme.dim
              font.pixelSize: Theme.type.tab.size
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
            spacing: Theme.space.line
            RowLayout {
              Layout.fillWidth: true
              spacing: Theme.space.tight
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: "⇣ from " + incoming.modelData.from + " · " + pane.agent + " decides, or you instead"
                color: Theme.dim
                font.pixelSize: Theme.type.tab.size
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
          font.pixelSize: Theme.type.body.size
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
      spacing: Theme.space.tight
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
