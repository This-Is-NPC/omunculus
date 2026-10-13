pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkView is one work on a page of its own. On top, the project it is in,
// its state and its title. Then its route, left to right: where it came
// from — the work that handed it down, or you through the conversation's
// agent; where it is now — the stages of its workflow, each with the agent
// that takes it, the one it is at lit, or the agent it is with; and where it
// goes — the works it handed down, then the next stage or whom it reports
// to. Each work on the route opens here. Below, its description, the goal it
// was given, where it works, what it asked and its notes, and beside them
// its runs, the files it changed or the prompt a run was given. Esc leaves.
FocusScope {
  id: view

  required property string key
  signal leave()
  signal picked(string key)

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property string agent: work ? Omunculus.agentOf(work) : ""
  readonly property var parentWork: work ? Omunculus.work(work.parent_id || "") : null
  readonly property var children: Omunculus.works.filter(item => item.parent_id === key)
  readonly property var running: Omunculus.running.find(run => (run.work_id || "") === key) || null
  // Its workflow's stages, {name, agent}, and the one it is at.
  readonly property var steps: {
    const flow = Omunculus.setup && work && work.workflow ? Omunculus.setup.workflows.find(each => each.name === work.workflow) : null
    return flow ? flow.steps : []
  }
  readonly property int at: steps.findIndex(step => step.name === (work ? work.stage : ""))
  readonly property bool finished: !!work && (work.state === "done" || work.state === "cancelled")
  // Whom it reports to when it is done: the agent of the work it came from,
  // or the conversation's.
  readonly property string reportsTo: parentWork ? Omunculus.agentOf(parentWork) : Omunculus.agent
  readonly property string stateText: !work ? ""
    : running ? "RUNNING"
    : work.state === "waiting" ? (work.waiting ? "WAITING ON A " + String(work.waiting).toUpperCase() : "BROKEN")
    : String(work.state).toUpperCase()
  readonly property color stateTone: running ? Theme.primary
    : work && work.state === "waiting" && !work.waiting ? Theme.error
    : Omunculus.stateTone(work ? work.state : "")

  // What the right shows: "runs", "changes" or "prompt".
  property string section: "runs"
  // The run whose prompt shows, or "" for the work's last.
  property string promptRun: ""
  onKeyChanged: {
    section = "runs"
    promptRun = ""
  }

  Keys.onEscapePressed: leave()

  // One leg of the route: a heading and what is there.
  component Leg: Rectangle {
    id: leg
    property string heading
    property bool lit: false
    default property alias body: legBody.data
    implicitHeight: legBody.implicitHeight + legHead.implicitHeight + 34
    color: lit ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.06)) : "transparent"
    border.color: lit ? Qt.alpha(Theme.primary, 0.7) : Theme.line
    Caption { id: legHead; x: 12; y: 12; text: leg.heading }
    ColumnLayout {
      id: legBody
      anchors { left: parent.left; right: parent.right; top: legHead.bottom; margins: 12; topMargin: 10 }
      spacing: 8
    }
  }

  // A work on the route, which opens here.
  component WorkLink: Rectangle {
    id: link
    required property var item
    Layout.fillWidth: true
    implicitHeight: linkText.implicitHeight + 16
    color: linkArea.containsMouse ? Qt.alpha(Theme.foreground, 0.05) : "transparent"
    border.color: linkArea.containsMouse || link.activeFocus ? Theme.primary : Theme.line
    activeFocusOnTab: true
    Keys.onReturnPressed: view.picked(link.item.id)
    Keys.onSpacePressed: view.picked(link.item.id)
    ColumnLayout {
      id: linkText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
      spacing: 2
      Label { Layout.fillWidth: true; text: link.item.title; font.pixelSize: 12; elide: Text.ElideRight }
      Label {
        Layout.fillWidth: true
        text: Omunculus.agentOf(link.item) + "  ·  " + String(link.item.state)
        color: Theme.dim
        font.pixelSize: 10
        elide: Text.ElideRight
      }
    }
    MouseArea {
      id: linkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.picked(link.item.id)
    }
  }

  component Arrow: Icon {
    Layout.alignment: Qt.AlignVCenter
    name: "chevron-right"
    color: Theme.dim
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 16

    // Where it is, and what.
    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Rectangle {
        implicitWidth: projectName.implicitWidth + 20
        implicitHeight: 24
        color: "transparent"
        border.color: Theme.line
        Label {
          id: projectName
          anchors.centerIn: parent
          text: "PROJECT  " + Omunculus.project.toUpperCase()
          color: Theme.foreground
          font.pixelSize: 10
          font.letterSpacing: 2
        }
      }
      Rectangle {
        implicitWidth: stateName.implicitWidth + 20
        implicitHeight: 24
        color: "transparent"
        border.color: view.stateTone
        Label {
          id: stateName
          anchors.centerIn: parent
          text: view.stateText
          color: view.stateTone
          font.pixelSize: 10
          font.letterSpacing: 2
        }
      }
      Label {
        Layout.fillWidth: true
        text: "in " + Omunculus.title
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
    DecodeLabel {
      Layout.fillWidth: true
      value: view.work ? view.work.title : ""
      font.pixelSize: 24
      font.letterSpacing: 1
      wrapMode: Text.Wrap
    }

    // Its route: from, now, to, the three as tall as the tallest.
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: false
      spacing: 10

      Leg {
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        heading: "FROM"
        WorkLink { visible: view.parentWork !== null; item: view.parentWork || ({ id: "", title: "", state: "" }) }
        Label {
          Layout.fillWidth: true
          visible: view.parentWork === null
          text: "you, through " + (Omunculus.agent || "the conversation's agent")
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
      }
      Arrow {}
      Leg {
        Layout.fillWidth: true
        Layout.preferredWidth: 1.4
        Layout.fillHeight: true
        heading: view.steps.length > 0 ? "NOW  ·  WORKFLOW " + String(view.work.workflow).toUpperCase() : "NOW"
        lit: !view.finished
        // Each stage and who takes it; the one it is at lit, those passed checked.
        Repeater {
          model: view.steps
          delegate: RowLayout {
            id: stage
            required property var modelData
            required property int index
            readonly property bool passed: view.finished || index < view.at
            readonly property bool current: !view.finished && index === view.at
            Layout.fillWidth: true
            spacing: 8
            Label {
              text: stage.passed ? "✓" : stage.current ? "▸" : "·"
              color: stage.current ? Theme.primary : Theme.dim
              font.pixelSize: 12
            }
            Label {
              text: stage.modelData.name
              color: stage.current ? Theme.primary : stage.passed ? Theme.foreground : Theme.dim
              font.pixelSize: 12
              font.bold: stage.current
            }
            Label {
              Layout.fillWidth: true
              text: stage.modelData.agent
              color: stage.current ? Omunculus.toneOf(stage.modelData.agent) : Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }
        RowLayout {
          visible: view.steps.length === 0
          spacing: 8
          Portrait { implicitWidth: 22; implicitHeight: 22; agent: view.agent }
          Label { text: "with " + view.agent; color: Omunculus.toneOf(view.agent); font.pixelSize: 12 }
        }
      }
      Arrow {}
      Leg {
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        heading: "TO"
        Repeater {
          model: view.children
          delegate: WorkLink {
            required property var modelData
            item: modelData
          }
        }
        Label {
          Layout.fillWidth: true
          text: view.finished ? "reported to " + view.reportsTo
            : view.at >= 0 && view.at < view.steps.length - 1
              ? "then " + view.steps[view.at + 1].name + ", with " + view.steps[view.at + 1].agent
              : "then reports to " + view.reportsTo
          color: Theme.dim
          font.pixelSize: 11
          wrapMode: Text.Wrap
        }
      }
    }

    // What it is for, and what it did.
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 20

      ScrollPage {
        id: side
        Layout.preferredWidth: Math.min(440, view.width * 0.45)
        Layout.fillHeight: true
        contentHeight: about.implicitHeight

        ColumnLayout {
          id: about
          width: side.width
          spacing: 12

          Caption { text: "DESCRIPTION" }
          Label {
            Layout.fillWidth: true
            text: view.work ? String(view.work.goal || "") : ""
            textFormat: Text.MarkdownText
            font.pixelSize: 13
            wrapMode: Text.Wrap
          }
          WorkSummary {
            Layout.fillWidth: true
            Layout.topMargin: 8
            key: view.key
            whole: false
            onPicked: key => view.picked(key)
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 12

        RowLayout {
          Layout.fillWidth: true
          spacing: 6
          Repeater {
            model: [
              { name: "runs", tip: "its runs: how each ended, failures, cost" },
              { name: "changes", tip: "the files it changed" },
              { name: "prompt", tip: "the prompt a run was given" }
            ]
            delegate: TraceButton {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              dense: true
              role: view.section === modelData.name ? "primary" : "action"
              text: modelData.name.toUpperCase()
              tip: modelData.tip
              onClicked: view.section = modelData.name
            }
          }
        }

        WorkRuns {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: view.section === "runs"
          key: view.key
          onPromptWanted: run => {
            view.promptRun = run
            view.section = "prompt"
          }
        }

        WorkChanges {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: view.section === "changes"
          key: view.key
        }

        WorkPrompt {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: view.section === "prompt"
          key: view.key
          run: view.promptRun
          onLatestWanted: view.promptRun = ""
        }
      }
    }
  }
}
