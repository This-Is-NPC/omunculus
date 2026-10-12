pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui"

// AgentNode is one agent at work on the orchestration map: its ring in the
// agent's colour, which keeps leaving it while the agent runs, the work, and
// its state as a sign — running, stopped, done, broken. What it asked and is
// still waiting for hangs from it: to you, with the options as buttons; to
// another agent, with that agent's name. So do the notes it left you. Clicking
// the node opens what the agent said and did.
SurfaceFrame {
  id: node

  // The work, or null for the root agent's own thread.
  required property var work
  required property string agent
  required property string title

  readonly property string key: work ? work.id : ""
  readonly property bool running: Omunculus.busy(key)
  readonly property var asks: Omunculus.asked(key)
  readonly property var notes: Omunculus.unreadFrom(key)
  readonly property bool yours: asks.some(request => Requests.human(request.arbiter)) || notes.length > 0
  readonly property string workState: work ? work.state : "open"
  readonly property color agentTone: Omunculus.toneOf(agent)
  // Clicking the node opens its thread.
  signal chosen()

  width: 240
  implicitHeight: content.implicitHeight + 24
  variant: yours ? "filled" : "outline"
  tone: yours ? Theme.warning : agentTone
  active: yours || running || pointer.containsMouse
  opacity: workState === "done" || workState === "cancelled" ? 0.55 : 1
  Behavior on opacity { NumberAnimation { duration: 200 } }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: node.chosen()
  }

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14; rightMargin: 14 }
    spacing: 8

    RowLayout {
      Layout.fillWidth: true
      spacing: 10

      Item {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 14
        implicitHeight: 14
        Rectangle {
          anchors.centerIn: parent
          width: 9
          height: 9
          radius: 4.5
          color: node.running ? node.agentTone : "transparent"
          border.color: node.agentTone
        }
        // A ring that keeps leaving the dot while the agent runs.
        Rectangle {
          id: ring
          anchors.centerIn: parent
          width: 9
          height: 9
          radius: width / 2
          color: "transparent"
          border.color: node.agentTone
          visible: node.running
          ParallelAnimation {
            running: node.running
            loops: Animation.Infinite
            NumberAnimation { target: ring; property: "width"; from: 9; to: 26; duration: 1400; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "height"; from: 9; to: 26; duration: 1400; easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: 1400 }
          }
        }
      }
      DecodeLabel {
        Layout.alignment: Qt.AlignVCenter
        value: node.agent.toUpperCase()
        color: node.agentTone
        font.pixelSize: 10
        font.letterSpacing: 3
      }
      Item { Layout.fillWidth: true }
      LoadingTrace {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: 56
        Layout.preferredHeight: 14
        visible: node.running
        running: node.running
        tone: node.agentTone
        backdrop: node.color
      }
      Icon {
        Layout.alignment: Qt.AlignVCenter
        visible: !node.running
        name: node.asks.length > 0 ? "warning" : { done: "check", broken: "warning", cancelled: "close" }[node.workState] || "pause"
        size: 12
        color: node.asks.length > 0 ? Theme.warning : Omunculus.stateTone(node.workState === "open" ? "" : node.workState)
      }
    }

    Label {
      Layout.fillWidth: true
      text: node.title
      font.pixelSize: 12
      maximumLineCount: 2
      elide: Text.ElideRight
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      visible: node.running && !!Omunculus.calling[node.key]
      text: Omunculus.calling[node.key] || ""
      color: Theme.dim
      font.pixelSize: 10
      font.italic: true
    }

    // What it asked and still waits for.
    Repeater {
      model: node.asks
      delegate: Rectangle {
        id: ask
        required property var modelData
        readonly property bool toYou: Requests.human(modelData.arbiter)
        Layout.fillWidth: true
        implicitHeight: asked.implicitHeight + 16
        color: toYou ? Qt.alpha(Theme.warning, 0.1) : Theme.highlight
        border.color: toYou ? Theme.warning : Theme.line

        ColumnLayout {
          id: asked
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8; leftMargin: 10; rightMargin: 10 }
          spacing: 6
          Row {
            spacing: 6
            Icon { anchors.verticalCenter: parent.verticalCenter; name: "chevron-right"; size: 10; color: ask.toYou ? Theme.warning : Theme.dim }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: ask.toYou ? "YOU" : Requests.label(ask.modelData.arbiter).toUpperCase()
              color: ask.toYou ? Theme.warning : Omunculus.toneOf(ask.modelData.arbiter.agent)
              font.pixelSize: 9
              font.letterSpacing: 2
            }
          }
          Label {
            Layout.fillWidth: true
            text: Omunculus.inline(Omunculus.reasons[ask.modelData.id] || "")
            textFormat: Text.MarkdownText
            color: Theme.foreground
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          RowLayout {
            Layout.fillWidth: true
            visible: ask.toYou && Object.keys(ask.modelData.options || {}).length === 0
            TextBox {
              id: response
              Layout.fillWidth: true
              dense: true
              placeholderText: "Answer the question"
              onAccepted: { if (text.trim()) Omunculus.reply(ask.modelData.id, "", text.trim()) }
            }
            TraceButton {
              dense: true
              role: "progress"
              text: "REPLY"
              enabled: response.text.trim().length > 0
              onClicked: Omunculus.reply(ask.modelData.id, "", response.text.trim())
            }
          }
          Flow {
            Layout.fillWidth: true
            visible: ask.toYou
            spacing: 6
            Repeater {
              model: Object.keys(ask.modelData.options || {})
              delegate: TraceButton {
                required property string modelData
                dense: true
                role: ["deny", "cancel"].includes(modelData) ? "guarded" : "progress"
                text: modelData.replace(/_/g, " ").toUpperCase()
                onClicked: Omunculus.reply(ask.modelData.id, modelData, "")
              }
            }
          }
        }
      }
    }

    // The notes it left you.
    Repeater {
      model: node.notes
      delegate: Rectangle {
        id: note
        required property var modelData
        Layout.fillWidth: true
        implicitHeight: noted.implicitHeight + 16
        color: Qt.alpha(Theme.warning, 0.1)
        border.color: Theme.warning
        RowLayout {
          id: noted
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8; leftMargin: 10; rightMargin: 8 }
          spacing: 8
          Label {
            Layout.fillWidth: true
            text: Omunculus.inline(Omunculus.notes[note.modelData.id] || "")
            textFormat: Text.MarkdownText
            font.pixelSize: 11
            wrapMode: Text.Wrap
          }
          IconButton { Layout.alignment: Qt.AlignTop; name: "check"; tip: "mark read"; onClicked: Omunculus.markRead(note.modelData.id) }
        }
      }
    }
  }
}
