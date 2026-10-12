pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "gui"

// ComposeView writes a new thread. To is required: one agent of depth 0 of one
// project, which the thread keeps; then what you need, in as many lines as it
// takes.
ColumnLayout {
  id: view

  // Whether a way back to the list shows, on a narrow window.
  property bool back: false
  property string project: ""
  property string agent: ""
  // Every agent a thread can be with, as {project, agent}.
  readonly property var recipients: Mail.projects.reduce((all, place) => all.concat(place.agents.map(name => ({ project: place.id, agent: name }))), [])

  spacing: 14

  function focusEntry() { body.focusEntry() }

  // With one agent to write to, it is the one.
  onRecipientsChanged: if (recipients.length === 1 && agent === "") { project = recipients[0].project; agent = recipients[0].agent }

  function submit() {
    if (agent === "" || body.text.trim() === "")
      return
    Mail.send(project, agent, body.take())
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    IconButton { visible: view.back; name: "chevron-left"; tip: "back to the list"; onClicked: Mail.close() }
    Label { Layout.fillWidth: true; text: "NEW THREAD"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 3 }
  }

  // To: each agent of depth 0, with its project.
  RowLayout {
    Layout.fillWidth: true
    spacing: 12
    Label { Layout.alignment: Qt.AlignTop; Layout.topMargin: 6; text: "To"; color: Theme.dim; font.pixelSize: 12 }
    Flow {
      Layout.fillWidth: true
      spacing: 6
      Repeater {
        model: view.recipients
        delegate: Rectangle {
          id: pick
          required property var modelData
          readonly property bool chosen: view.project === modelData.project && view.agent === modelData.agent
          implicitWidth: row.implicitWidth + 20
          implicitHeight: 28
          color: chosen ? Qt.alpha(Theme.primary, 0.12) : pointer.containsMouse ? Qt.alpha(Theme.foreground, 0.04) : "transparent"
          border.color: chosen ? Theme.primary : Theme.line
          Row {
            id: row
            anchors.centerIn: parent
            spacing: 8
            Label { anchors.verticalCenter: parent.verticalCenter; text: pick.modelData.agent; color: pick.chosen ? Theme.primary : Theme.foreground; font.pixelSize: 12 }
            ProjectTag { anchors.verticalCenter: parent.verticalCenter; name: pick.modelData.project }
          }
          MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { view.project = pick.modelData.project; view.agent = pick.modelData.agent }
          }
        }
      }
      Label {
        visible: view.recipients.length === 0
        text: Mail.connected ? "reading the agents..." : "the server does not answer"
        color: Theme.dim
        font.pixelSize: 12
      }
    }
  }

  Label {
    Layout.fillWidth: true
    text: view.agent === "" ? "Choose who it is for. The thread stays with that agent."
      : view.agent + " in " + view.project + " gets it; you hear back here, and questions for you come into the thread."
    color: view.agent === "" ? Theme.warning : Theme.dim
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }

  Editor {
    id: body
    Layout.fillWidth: true
    Layout.fillHeight: true
    placeholderText: "what you need"
    onSubmitted: view.submit()
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: 8
    Item { Layout.fillWidth: true }
    TraceButton {
      dense: true
      role: "progress"
      text: "DISCARD"
      onClicked: { body.text = ""; Mail.close() }
    }
    TraceButton {
      dense: true
      role: "primary"
      icon: "send"
      text: "SEND"
      enabled: view.agent !== "" && body.text.trim() !== "" && Mail.connected
      tip: "ctrl+enter"
      onClicked: view.submit()
    }
  }
}
