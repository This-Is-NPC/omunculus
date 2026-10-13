import QtQuick
import QtQuick.Layouts
import "kit/ui"

// BoardCard is one work on the board, the work first: the project it is of
// and its title; in a workflow, the stage it is at, of how many, and,
// waiting, what on; the conversation it is in and the work it came from;
// then, smaller, the agent it is with and how long since it last changed. Its border is the accent
// while an agent runs on it; a work that is done or cancelled shows faded.
// The keyboard reaches it; Enter or Space, or a click, opens it.
Rectangle {
  id: card

  required property var work
  // The time now, in milliseconds, which the age follows.
  property real now: Date.now()
  signal opened()

  readonly property string agent: Omunculus.agentOf(work)
  readonly property var lane: Omunculus.laneOf(work)
  readonly property bool running: Omunculus.boardBusy.includes(work.project + "/" + work.id)
  readonly property var parentWork: work.parent_id ? Omunculus.board.find(item => item.project === work.project && item.id === work.parent_id) || null : null
  readonly property string where: [
    lane ? lane.name.toUpperCase() + " " + String(lane.at + 1).padStart(2, "0") + "/" + String(lane.steps.length).padStart(2, "0") + " " + lane.steps[lane.at].name.toUpperCase() : "",
    work.state === "waiting" && work.waiting ? "ON A " + work.waiting.toUpperCase() : ""
  ].filter(part => part !== "").join("  ·  ")
  readonly property string age: Omunculus.ago(work.updated_at || work.created_at, now)

  implicitHeight: details.implicitHeight + 24
  activeFocusOnTab: true
  Keys.onReturnPressed: opened()
  Keys.onSpacePressed: opened()
  color: pointer.containsMouse ? Theme.highlight : Theme.background
  border.color: running ? Theme.primary : Theme.line
  border.width: running ? 2 : 1
  opacity: work.state === "done" || work.state === "cancelled" ? 0.6 : 1
  Behavior on color { ColorAnimation { duration: 140 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }

  ColumnLayout {
    id: details
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
    spacing: 5

    Label {
      Layout.fillWidth: true
      text: card.work.project.toUpperCase()
      color: Theme.dim
      font.pixelSize: 9
      font.letterSpacing: 2
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      text: card.work.title
      color: Theme.foreground
      font.pixelSize: 15
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      visible: card.where !== ""
      text: card.where
      color: Theme.primary
      font.pixelSize: 9
      font.letterSpacing: 1.5
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      text: "in " + Omunculus.conversationLabel(card.work.conversation_id)
      color: Theme.dim
      font.pixelSize: 10
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      visible: card.parentWork !== null
      text: card.parentWork ? "under " + card.parentWork.title : ""
      color: Theme.dim
      font.pixelSize: 10
      elide: Text.ElideRight
    }
    RowLayout {
      Layout.fillWidth: true
      Layout.topMargin: 3
      spacing: 6
      Portrait {
        Layout.preferredWidth: 18
        Layout.preferredHeight: 18
        agent: card.agent
        source: Omunculus.imageOf(card.agent, card.work.project)
        tone: Omunculus.toneOf(card.agent)
        initialSize: 9
      }
      Label {
        Layout.fillWidth: true
        text: card.agent
        color: Omunculus.toneOf(card.agent)
        font.pixelSize: 10
        elide: Text.ElideRight
      }
      Label {
        visible: card.running
        text: "RUNNING"
        color: Theme.primary
        font.pixelSize: 9
        font.letterSpacing: 2
      }
      Label {
        text: card.age
        color: Theme.dim
        font.pixelSize: 10
      }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { card.forceActiveFocus(); card.opened() }
  }
  FocusRing {}
}
