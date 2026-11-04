pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui"

// AgentNode is one work on the TEAM page's map, a card the map sizes: the
// portrait and name of the agent that has it, its state, its title and its
// stages; under them a badge for what it waits on (⇡) and one for what it is
// asked (⇣). Its border is its state's tone; picked, or at one end of the
// request picked, it is drawn in full. The keyboard reaches it; Enter or
// Space picks it.
Rectangle {
  id: card

  // A node of Omunculus.progress.
  required property var node
  property bool selected: false
  property bool highlighted: false
  signal chosen()
  signal requestPicked(string id)

  readonly property color agentTone: Omunculus.toneOf(node.agent)
  readonly property var asks: node.asks
  readonly property var asked: node.asked
  readonly property bool quiet: ["done", "cancelled"].includes(node.state)
  readonly property real now: Omunculus.tick
  readonly property string clock: node.state === "working" && node.since !== null
    ? Progress.clock(Math.max(0, Math.round(now - node.since))) : ""

  activeFocusOnTab: true
  Keys.onReturnPressed: chosen()
  Keys.onSpacePressed: chosen()
  Accessible.role: Accessible.Button
  Accessible.name: node.agent + ", " + node.word + ", " + node.title
  color: selected ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.1)) : pointer.containsMouse ? Theme.highlight : Theme.background
  border.color: highlighted ? Theme.warning : selected ? Theme.primary : mark.tone
  border.width: selected || highlighted || node.state === "working" || node.state === "needs-you" ? 2 : 1
  opacity: quiet && !selected ? 0.7 : 1
  Behavior on color { ColorAnimation { duration: 140 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { card.forceActiveFocus(); card.chosen() }
  }

  RowLayout {
    anchors { fill: parent; margins: Theme.space.tight }
    spacing: Theme.space.tight

    Portrait {
      Layout.alignment: Qt.AlignTop
      Layout.preferredWidth: 32
      Layout.preferredHeight: 32
      agent: card.node.agent
      source: Omunculus.imageOf(card.node.agent)
      tone: card.agentTone
      framed: true
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.minimumWidth: 0
      spacing: Theme.space.row

      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.tight
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: card.node.agent
          color: card.agentTone
          font.pixelSize: 12
          font.bold: true
          elide: Text.ElideRight
        }
        StateMark {
          id: mark
          Layout.maximumWidth: 110
          state: card.node.state
          clock: card.clock
        }
      }
      Label {
        Layout.fillWidth: true
        text: card.node.title
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Stepper {
        Layout.fillWidth: true
        steps: card.node.steps
        round: card.node.round
      }
      Item { Layout.fillHeight: true }
      // What it waits on and what it is asked; each badge picks its request.
      RowLayout {
        Layout.fillWidth: true
        visible: card.asks.length > 0 || card.asked.length > 0
        spacing: Theme.space.gap
        Label {
          visible: card.asks.length > 0
          Layout.fillWidth: true
          Layout.maximumWidth: implicitWidth
          Layout.minimumWidth: 0
          text: card.asks.length > 0 ? "⇡ " + (card.asks[0].human ? "you" : card.asks[0].to) + (card.asks.length > 1 ? " +" + (card.asks.length - 1) : "") : ""
          color: card.asks.some(ask => ask.human) ? Theme.warning : Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideRight
          TapHandler { onTapped: card.requestPicked(card.asks[0].id) }
        }
        Label {
          visible: card.asked.length > 0
          Layout.fillWidth: true
          Layout.maximumWidth: implicitWidth
          Layout.minimumWidth: 0
          text: "⇣ " + card.asked.length + (card.asked.length === 1 ? " question" : " questions")
          color: Theme.foreground
          font.pixelSize: 11
          elide: Text.ElideRight
          TapHandler { onTapped: card.requestPicked(card.asked[0].id) }
        }
        Item { Layout.fillWidth: true }
      }
    }
  }
  FocusRing {}
}
