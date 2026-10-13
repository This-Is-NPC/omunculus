pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AgentInspector is the node picked on the agents map, beside it: the agent,
// its portrait and model; while it runs, what it is doing now — for how
// long, the tool it called last; the work — where it stands in its workflow,
// its goal, state, where it works and the work it came from; what it asked
// and still waits for, to answer in place; the notes it left you; then what
// it said and did, run by run, and a composer to write to it.
Rectangle {
  id: inspector

  // The work, or "" for the root agent's own conversation.
  required property string key
  required property string agent
  signal closed()
  signal picked(string key)

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property var parentWork: work ? Omunculus.work(work.parent_id || "") : null
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")
  readonly property color agentTone: Omunculus.toneOf(agent)
  // The run of the work open now, if any, and the time, to count how long.
  readonly property var running: Omunculus.running.find(run => (run.work_id || "") === key) || null
  property real now: Date.now()
  Timer { interval: 1000; repeat: true; running: inspector.running !== null && inspector.visible; onTriggered: inspector.now = Date.now() }
  readonly property int seconds: running && running.started_at ? Math.max(0, Math.round((now - Date.parse(running.started_at)) / 1000)) : 0

  function focusEntry() { composer.focusEntry() }

  color: Theme.background
  border.color: Theme.line

  ColumnLayout {
    anchors { fill: parent; margins: 14 }
    spacing: 12

    RowLayout {
      Layout.fillWidth: true
      spacing: 12
      Item {
        Layout.alignment: Qt.AlignTop
        implicitWidth: 72
        implicitHeight: 72
        Rectangle { anchors.fill: parent; color: Qt.alpha(inspector.agentTone, 0.08); border.color: Theme.line }
        Label {
          anchors.centerIn: parent
          visible: face.status !== Image.Ready
          text: inspector.agent.charAt(0).toUpperCase()
          color: inspector.agentTone
          font.pixelSize: 32
        }
        Image {
          id: face
          anchors { fill: parent; margins: 1 }
          source: Omunculus.imageOf(inspector.agent)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          smooth: true
          mipmap: true
        }
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

    ScrollPage {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(facts.implicitHeight, inspector.height * 0.55)
      contentHeight: facts.implicitHeight

      ColumnLayout {
        id: facts
        width: parent.width
        spacing: 10

        Label {
          Layout.fillWidth: true
          text: inspector.work ? inspector.work.title : Omunculus.title
          font.pixelSize: 13
          wrapMode: Text.Wrap
        }
        Label {
          Layout.fillWidth: true
          visible: inspector.work !== null && !!inspector.work.goal && inspector.work.goal !== inspector.work.title
          text: inspector.work ? Omunculus.inline(String(inspector.work.goal || "")) : ""
          textFormat: Text.MarkdownText
          color: Theme.dim
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }

        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: 12
          rowSpacing: 6
          Caption { text: "WORKSPACE" }
          Label {
            Layout.fillWidth: true
            text: (inspector.place.name ? inspector.place.name + "  ·  " : "") + inspector.place.root
            font.pixelSize: 11
            elide: Text.ElideMiddle
          }
          Caption { visible: !!inspector.work && !!inspector.work.workflow; text: "WORKFLOW" }
          Label {
            visible: !!inspector.work && !!inspector.work.workflow
            text: inspector.work && inspector.work.workflow ? inspector.work.workflow + "  ·  stage " + inspector.work.stage : ""
            font.pixelSize: 11
          }
          Caption { visible: inspector.parentWork !== null; text: "FROM" }
          Label {
            visible: inspector.parentWork !== null
            text: inspector.parentWork ? (inspector.parentWork.assignee || "").toUpperCase() + "  ·  " + inspector.parentWork.title : ""
            color: from.containsMouse ? Theme.primary : Theme.foreground
            font.pixelSize: 11
            font.underline: from.containsMouse
            elide: Text.ElideRight
            Layout.fillWidth: true
            MouseArea {
              id: from
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: inspector.picked(inspector.parentWork.id)
            }
          }
        }

        Repeater {
          model: Omunculus.asked(inspector.key)
          delegate: RequestDecision {
            required property var modelData
            Layout.fillWidth: true
            key: modelData.id
            stamp: String(modelData.created_at).slice(11, 16)
          }
        }

        Repeater {
          model: Omunculus.unreadFrom(inspector.key)
          delegate: SurfaceFrame {
            id: note
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: noted.implicitHeight + 20
            variant: "filled"
            tone: Theme.warning
            RowLayout {
              id: noted
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10; leftMargin: 12 }
              spacing: 8
              Label {
                Layout.fillWidth: true
                text: Omunculus.inline(Omunculus.notes[note.modelData.id] || "")
                textFormat: Text.MarkdownText
                font.pixelSize: 12
                wrapMode: Text.Wrap
              }
              IconButton { Layout.alignment: Qt.AlignTop; name: "check"; tip: "mark read"; onClicked: Omunculus.markRead(note.modelData.id) }
            }
          }
        }
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
}
