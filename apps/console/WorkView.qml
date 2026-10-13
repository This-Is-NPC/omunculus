pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkView is one work on a page of its own: its title, state and project
// over two columns. On the left, its agent's portrait and model, where it
// stands in its workflow, its description — the goal it was given — what
// it asked and the notes it left, and the works around it — the one it came from and those it handed
// down — each opening here. On the right, its runs, the files it changed or
// the prompt a run was given. Esc leaves.
FocusScope {
  id: view

  required property string key
  signal leave()
  signal picked(string key)

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property string agent: work ? Omunculus.agentOf(work) : ""
  readonly property color agentTone: Omunculus.toneOf(agent)
  readonly property var parentWork: work ? Omunculus.work(work.parent_id || "") : null
  readonly property var children: Omunculus.works.filter(item => item.parent_id === key)
  readonly property var running: Omunculus.running.find(run => (run.work_id || "") === key) || null

  // What the right shows: "runs", "changes" or "prompt".
  property string section: "runs"
  // The run whose prompt shows, or "" for the work's last.
  property string promptRun: ""
  onKeyChanged: {
    section = "runs"
    promptRun = ""
  }

  Keys.onEscapePressed: leave()

  RowLayout {
    anchors.fill: parent
    spacing: 20

    ScrollPage {
      id: side
      Layout.preferredWidth: Math.min(360, view.width * 0.42)
      Layout.fillHeight: true
      contentHeight: about.implicitHeight

      ColumnLayout {
        id: about
        width: side.width
        spacing: 14

        Label {
          text: "WORK" + (view.work ? "  ·  " + String(view.work.state).toUpperCase() + (view.running ? "  ·  RUNNING" : "") : "")
          color: view.running ? view.agentTone : Omunculus.stateTone(view.work ? view.work.state : "")
          font.pixelSize: 10
          font.letterSpacing: 3
        }
        DecodeLabel {
          Layout.fillWidth: true
          value: view.work ? view.work.title : ""
          font.pixelSize: 20
          font.letterSpacing: 1
          wrapMode: Text.Wrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 12
          Portrait {
            implicitWidth: 64
            implicitHeight: 64
            agent: view.agent
            framed: true
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            DecodeLabel { value: view.agent; color: view.agentTone; font.pixelSize: 14; font.letterSpacing: 2 }
            Label {
              Layout.fillWidth: true
              text: Omunculus.modelOf(view.agent)
              color: Theme.dim
              font.pixelSize: 10
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              text: Omunculus.project + "  ·  " + Omunculus.title
              color: Theme.dim
              font.pixelSize: 10
              elide: Text.ElideRight
            }
          }
        }

        Caption { text: "DESCRIPTION" }
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: goal.implicitHeight + 24
          color: "transparent"
          border.color: Theme.line
          Label {
            id: goal
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            text: view.work ? String(view.work.goal || "") : ""
            textFormat: Text.MarkdownText
            font.pixelSize: 12
            wrapMode: Text.Wrap
          }
        }

        WorkflowTrack {
          Layout.fillWidth: true
          work: view.work
          tone: view.agentTone
          running: view.running !== null
        }

        WorkSummary {
          Layout.fillWidth: true
          key: view.key
          titled: false
          onPicked: key => view.picked(key)
        }

        Caption { visible: view.children.length > 0; text: "HANDED DOWN" }
        Flow {
          Layout.fillWidth: true
          visible: view.children.length > 0
          spacing: 6
          Repeater {
            model: view.children
            delegate: Chip {
              required property var modelData
              text: modelData.title
              tip: "open " + (modelData.assignee || "") + "'s work"
              onClicked: view.picked(modelData.id)
            }
          }
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
