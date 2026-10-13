pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AgentInspector is the node picked on the agents map, beside it: the agent,
// its portrait and model; while it runs, what it is doing now — for how
// long, the tool it called last; the work — where it stands in its workflow,
// its goal, state, where it works and the work it came from; what it asked
// and still waits for, to answer in place; the notes it left you; then what
// it said and did, run by run, and a composer to write to it. Beside the
// work, its runs summed up and each call by call, the files it changed and
// their diff, and the prompt a run was given.
Rectangle {
  id: inspector

  // The work, or "" for the root agent's own conversation.
  required property string key
  required property string agent
  signal closed()
  signal picked(string key)

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property color agentTone: Omunculus.toneOf(agent)
  // The run of the work open now, if any, and the time, to count how long.
  readonly property var running: Omunculus.running.find(run => (run.work_id || "") === key) || null
  property real now: Date.now()
  Timer { interval: 1000; repeat: true; running: inspector.running !== null && inspector.visible; onTriggered: inspector.now = Date.now() }
  readonly property int seconds: running && running.started_at ? Math.max(0, Math.round((now - Date.parse(running.started_at)) / 1000)) : 0

  // What it shows: "work", "runs", "changes" or "prompt".
  property string section: "work"
  // The run whose prompt shows, or "" for the work's last.
  property string promptRun: ""
  onKeyChanged: promptRun = ""

  // Shows the work and puts the keyboard in its composer, to write to it or,
  // `noting`, to leave it a note.
  function write(noting) {
    section = "work"
    composer.focusEntry(noting)
  }

  color: Theme.background
  border.color: Theme.line

  // What is not a control here is still the inspector: a click or the wheel
  // on it does not reach the map below.
  MouseArea {
    anchors.fill: parent
    onWheel: wheel => wheel.accepted = true
  }

  ColumnLayout {
    anchors { fill: parent; margins: 14 }
    spacing: 12

    RowLayout {
      Layout.fillWidth: true
      spacing: 12
      Portrait {
        Layout.alignment: Qt.AlignTop
        implicitWidth: 72
        implicitHeight: 72
        agent: inspector.agent
        source: Omunculus.imageOf(inspector.agent)
        tone: Omunculus.toneOf(inspector.agent)
        framed: true
      }
      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        spacing: 4
        DecodeLabel { value: inspector.agent; color: inspector.agentTone; font.pixelSize: 17; font.letterSpacing: 2 }
        Label {
          Layout.fillWidth: true
          text: Omunculus.modelOf(inspector.agent)
          color: Theme.dim
          font.pixelSize: 10
          elide: Text.ElideRight
        }
        Label {
          Layout.fillWidth: true
          text: inspector.running ? "RUNNING  ·  " + inspector.seconds + " S"
            + (Omunculus.calling[inspector.key] ? "  ·  NOW " + String(Omunculus.calling[inspector.key]).toUpperCase() : "")
            : inspector.work ? String(inspector.work.state).toUpperCase() : "IDLE"
          color: inspector.running ? inspector.agentTone : Omunculus.stateTone(inspector.work ? inspector.work.state : "")
          font.pixelSize: 10
          font.letterSpacing: 2
          elide: Text.ElideRight
        }
      }
      IconButton { Layout.alignment: Qt.AlignTop; name: "close"; tip: "esc"; onClicked: inspector.closed() }
    }

    WorkflowTrack {
      Layout.fillWidth: true
      work: inspector.work
      tone: inspector.agentTone
      running: inspector.running !== null
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 6
      Repeater {
        model: [
          { name: "work", tip: "the work, what it said and did" },
          { name: "runs", tip: "its runs: how each ended, failures, cost" },
          { name: "changes", tip: "the files it changed" },
          { name: "prompt", tip: "the prompt a run was given" }
        ]
        delegate: TraceButton {
          required property var modelData
          Layout.fillWidth: true
          Layout.preferredWidth: 1
          dense: true
          role: inspector.section === modelData.name ? "primary" : "action"
          text: modelData.name.toUpperCase()
          tip: modelData.tip
          onClicked: inspector.section = modelData.name
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: inspector.section === "work"
      spacing: 12

      ScrollPage {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(facts.implicitHeight, inspector.height * 0.55)
        contentHeight: facts.implicitHeight

        WorkSummary {
          id: facts
          width: parent.width
          key: inspector.key
          onPicked: key => inspector.picked(key)
        }
      }

      Kicker { Layout.fillWidth: true; text: "its runs: what it said and did" }

      TimelineView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        thread: Omunculus.threadOf(inspector.key)
        emptyText: "NOTHING SAID HERE YET"
        requestsShown: false
      }

      Composer {
        id: composer
        Layout.fillWidth: true
        compact: true
        pendingShown: false
        work: inspector.key
      }
    }

    WorkRuns {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: inspector.section === "runs"
      key: inspector.key
      onPromptWanted: run => {
        inspector.promptRun = run
        inspector.section = "prompt"
      }
    }

    WorkChanges {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: inspector.section === "changes"
      key: inspector.key
    }

    WorkPrompt {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: inspector.section === "prompt"
      key: inspector.key
      run: inspector.promptRun
      onLatestWanted: inspector.promptRun = ""
    }
  }
}
