pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// WorkView is one work on a page of its own, as an issue is read: where it
// is — its project, its conversation, the work it came from — and its title
// on top; then, on the left, what it is for, what it asked and its notes,
// and under them its runs, the files it changed or the prompt a run was
// given; on the right, its properties: its state, its project, its workflow
// with each stage over the agent that takes it, or the agent it is with,
// where it came from and the works it handed down, each opening here, whom
// it goes to next, where it works and when it began and last changed. On a
// narrow page the properties follow the description instead.
// Esc leaves.
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

  // The time now, which the ages follow.
  property real now: Date.now()
  Timer { interval: 30000; repeat: true; running: view.visible; onTriggered: view.now = Date.now() }
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")

  // What shows under the description: "runs", "changes" or "prompt".
  property string section: "runs"
  // The run whose prompt shows, or "" for the work's last.
  property string promptRun: ""
  onKeyChanged: {
    section = "runs"
    promptRun = ""
  }

  // Whether the properties sit under the description rather than beside it.
  readonly property bool stacked: Breakpoints.size(width) === "narrow"

  Keys.onEscapePressed: leave()

  // A property of the work: its name over what it is.
  component Property: ColumnLayout {
    id: property
    property string name
    default property alias body: value.data
    Layout.fillWidth: true
    spacing: 4
    Caption { text: property.name }
    ColumnLayout {
      id: value
      Layout.fillWidth: true
      spacing: 4
    }
  }

  // A property's plain value.
  component Value: Label {
    Layout.fillWidth: true
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }

  // Another work, its title over its agent and state, which opens here.
  component WorkLink: Item {
    id: link
    required property var item
    Layout.fillWidth: true
    implicitHeight: linkText.implicitHeight + 4
    activeFocusOnTab: true
    Keys.onReturnPressed: view.picked(link.item.id)
    Keys.onSpacePressed: view.picked(link.item.id)
    FocusRing {}
    ColumnLayout {
      id: linkText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 1
      Label {
        Layout.fillWidth: true
        text: link.item.title
        color: linkArea.containsMouse ? Theme.primary : Theme.foreground
        font.pixelSize: 12
        font.underline: linkArea.containsMouse
        elide: Text.ElideRight
      }
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

  // Its properties, one under the other.
  component PropertyList: ColumnLayout {
    spacing: 16

    Property {
      name: "STATE"
      Value { text: view.stateText; color: view.stateTone; font.letterSpacing: 1 }
    }
    Property {
      name: "PROJECT"
      Value { text: Omunculus.project }
    }
    Property {
      name: view.steps.length > 0 ? "WORKFLOW  ·  " + String(view.work.workflow).toUpperCase() : "WITH"
      // Each stage over the agent that takes it: passed checked, the
      // one it is at lit.
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
            Layout.preferredWidth: 10
            text: stage.passed ? "✓" : stage.current ? "▸" : "·"
            color: stage.current ? Theme.primary : Theme.dim
            font.pixelSize: 12
          }
          Label {
            Layout.preferredWidth: Math.min(implicitWidth, stage.width * 0.45)
            text: stage.modelData.name
            color: stage.current ? Theme.primary : stage.passed ? Theme.foreground : Theme.dim
            font.pixelSize: 12
            elide: Text.ElideRight
          }
          Portrait { implicitWidth: 18; implicitHeight: 18; agent: stage.modelData.agent; source: Omunculus.imageOf(stage.modelData.agent); tone: Omunculus.toneOf(stage.modelData.agent) }
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
        Portrait { implicitWidth: 18; implicitHeight: 18; agent: view.agent; source: Omunculus.imageOf(view.agent); tone: Omunculus.toneOf(view.agent) }
        Value { text: view.agent; color: Omunculus.toneOf(view.agent) }
      }
    }
    Property {
      name: "FROM"
      WorkLink { visible: view.parentWork !== null; item: view.parentWork || ({ id: "", title: "", state: "" }) }
      Value { visible: view.parentWork === null; text: "you, through " + (Omunculus.agent || "the conversation's agent") }
    }
    Property {
      name: view.children.length > 0 ? "HANDED DOWN  ·  " + view.children.length : "HANDED DOWN"
      Repeater {
        model: view.children
        delegate: WorkLink {
          required property var modelData
          item: modelData
        }
      }
      Value { visible: view.children.length === 0; text: "nothing"; color: Theme.dim }
    }
    Property {
      name: view.finished ? "REPORTED TO" : "NEXT"
      Value {
        text: view.finished ? view.reportsTo
          : view.at >= 0 && view.at < view.steps.length - 1
            ? view.steps[view.at + 1].name + ", with " + view.steps[view.at + 1].agent
            : "reports to " + view.reportsTo
      }
    }
    Property {
      name: "WORKSPACE"
      Value { text: (view.place.name ? view.place.name + "  ·  " : "") + view.place.root; elide: Text.ElideMiddle; wrapMode: Text.NoWrap }
    }
    Property {
      name: "BEGAN  ·  CHANGED"
      Value {
        text: view.work ? Omunculus.ago(view.work.created_at, view.now) + " ago  ·  "
          + Omunculus.ago(view.work.updated_at || view.work.created_at, view.now) + " ago" : ""
        color: Theme.dim
      }
    }
  }
  Component { id: propertyList; PropertyList {} }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    // Where it is: its project, its conversation, the work it came from.
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.maximumWidth: view.width * 0.3
        text: Omunculus.project.toUpperCase()
        color: Theme.primary
        font.pixelSize: 11
        font.letterSpacing: 3
        elide: Text.ElideRight
      }
      Label { text: "/"; color: Theme.dim; font.pixelSize: 11 }
      Label {
        Layout.maximumWidth: view.width * 0.3
        text: Omunculus.title
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
      Label { visible: view.parentWork !== null; text: "/"; color: Theme.dim; font.pixelSize: 11 }
      Label {
        Layout.fillWidth: true
        visible: view.parentWork !== null
        text: view.parentWork ? view.parentWork.title : ""
        color: crumb.containsMouse ? Theme.primary : Theme.dim
        font.pixelSize: 11
        font.underline: crumb.containsMouse
        elide: Text.ElideRight
        MouseArea {
          id: crumb
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.picked(view.parentWork.id)
        }
      }
      Item { Layout.fillWidth: view.parentWork === null }
    }
    DecodeLabel {
      Layout.fillWidth: true
      value: view.work ? view.work.title : ""
      font.pixelSize: 24
      font.letterSpacing: 1
      wrapMode: Text.Wrap
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 0

      // The work: what it is for, then what it did.
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.rightMargin: view.stacked ? 0 : 20
        spacing: 12

        Caption { Layout.topMargin: 6; text: "DESCRIPTION" }
        ScrollPage {
          id: described
          Layout.fillWidth: true
          // As tall as it reads, up to two fifths of the room, or half
          // with the properties under it.
          Layout.preferredHeight: Math.min(about.implicitHeight, view.height * (view.stacked ? 0.5 : 0.4))
          contentHeight: about.implicitHeight

          ColumnLayout {
            id: about
            width: described.width
            spacing: 12
            Prose {
              Layout.fillWidth: true
              source: view.work ? String(view.work.goal || "") : ""
              font.pixelSize: 14
              lineHeight: 1.2
              wrapMode: Text.Wrap
            }
            WorkSummary {
              Layout.fillWidth: true
              key: view.key
              whole: false
              onPicked: key => view.picked(key)
            }
            Loader {
              Layout.fillWidth: true
              Layout.topMargin: 6
              active: view.stacked
              visible: active
              sourceComponent: propertyList
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: 8
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
              Layout.preferredWidth: 120
              Layout.maximumWidth: 120
              dense: true
              role: view.section === modelData.name ? "primary" : "action"
              text: modelData.name.toUpperCase()
              tip: modelData.tip
              onClicked: view.section = modelData.name
            }
          }
          Item { Layout.fillWidth: true }
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

      Rectangle { visible: !view.stacked; Layout.fillHeight: true; implicitWidth: 1; color: Theme.line }

      // Its properties, beside the work.
      ScrollPage {
        id: properties
        visible: !view.stacked
        Layout.preferredWidth: Math.min(300, view.width * 0.36)
        Layout.fillHeight: true
        contentHeight: beside.implicitHeight + 12

        Loader {
          id: beside
          x: 20
          y: 6
          width: properties.width - 20
          active: !view.stacked
          sourceComponent: propertyList
        }
      }
    }
  }
}
