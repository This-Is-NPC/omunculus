pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui"

// AgentPicker is whom a new conversation is with: a card for each agent of
// depth 0 that is not only in workflows — its portrait, its name in its
// colour and its role, the first sentence of its text; the model it runs on
// is in a tooltip. Nothing is chosen the first time: a click, a number, or the
// arrows and Enter pick one. Afterwards the agent last talked to comes first,
// chosen and marked. Esc goes back.
FocusScope {
  id: picker

  signal picked(string name)
  signal back()

  // The last agent talked to first, the others in the order of the setup.
  readonly property var agents: {
    const all = Omunculus.talkable
    const last = all.find(each => each.name === Omunculus.lastAgent)
    return last ? [last].concat(all.filter(each => each !== last)) : all
  }
  // The card chosen to begin with: the first when it is the last used.
  readonly property int start: Omunculus.lastAgent !== "" && agents.length > 0 && agents[0].name === Omunculus.lastAgent ? 0 : -1
  readonly property real card: 220

  // The role of an agent: the first sentence of its text without "You are the".
  function role(text) {
    const sentence = (text || "").split(/[.:\n]/)[0].replace(/^\s*You are( the| an?)?\s+/i, "").trim()
    return sentence.charAt(0).toUpperCase() + sentence.slice(1)
  }

  onVisibleChanged: if (visible) grid.currentIndex = start
  onAgentsChanged: grid.currentIndex = start

  Keys.onEscapePressed: back()
  // The digits pick only with the cards in hand and no text just written.
  Keys.onPressed: event => {
    if (!grid.activeFocus || !Typing.idle)
      return
    const index = Shortcuts.keys("pick").indexOf(event.text)
    if (index >= 0 && index < agents.length) {
      picked(agents[index].name)
      event.accepted = true
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 18

    DecodeLabel {
      Layout.alignment: Qt.AlignHCenter
      value: "WHO DO YOU WANT TO TALK WITH"
      color: Theme.dim
      font.pixelSize: 11
      font.letterSpacing: 4
    }

    GridView {
      id: grid
      Layout.fillWidth: true
      Layout.fillHeight: true
      // Centred: as many cards a row as fit.
      readonly property int across: Math.max(1, Math.min(picker.agents.length, Math.floor(width / cellWidth)))
      leftMargin: (width - across * cellWidth) / 2
      cellWidth: picker.card + 16
      cellHeight: picker.card + 116
      clip: true
      focus: true
      currentIndex: picker.start
      keyNavigationEnabled: true
      model: picker.agents
      // The first arrow lands on the first card instead of moving from none.
      Keys.onPressed: event => {
        if (currentIndex < 0 && [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].includes(event.key)) {
          currentIndex = 0
          event.accepted = true
        }
      }
      Keys.onReturnPressed: if (currentItem) picker.picked(picker.agents[currentIndex].name)
      Keys.onEnterPressed: if (currentItem) picker.picked(picker.agents[currentIndex].name)

      delegate: Rectangle {
        id: cardItem
        required property var modelData
        required property int index
        readonly property bool current: GridView.isCurrentItem && grid.activeFocus
        width: picker.card
        height: picker.card + 100
        color: current || pointer.containsMouse ? Theme.highlight : "transparent"
        border.color: current ? Theme.primary : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.5) : Theme.line
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Portrait {
          id: portrait
          x: 1
          y: 1
          width: parent.width - 2
          height: width
          agent: cardItem.modelData.name
          source: Omunculus.imageOf(cardItem.modelData.name)
          tone: Omunculus.toneOf(cardItem.modelData.name)
          initialSize: 72
        }
        Label {
          anchors { right: parent.right; top: parent.top; margins: 8 }
          visible: cardItem.modelData.name === Omunculus.lastAgent
          text: "LAST USED"
          color: Theme.primary
          font.pixelSize: 11
          padding: 4
          Rectangle { anchors.fill: parent; z: -1; color: Theme.background; border.color: Theme.line }
        }
        Label {
          x: 8
          y: 8
          visible: cardItem.index < 9
          text: String(cardItem.index + 1)
          color: Theme.primary
          font.pixelSize: 11
          padding: 4
          Rectangle { anchors.fill: parent; z: -1; color: Theme.background; border.color: Theme.line }
        }

        Column {
          anchors { left: parent.left; right: parent.right; top: portrait.bottom; margins: 12 }
          spacing: 4
          DecodeLabel {
            width: parent.width
            value: cardItem.modelData.name
            color: Omunculus.toneOf(cardItem.modelData.name)
            font.pixelSize: 15
            font.letterSpacing: 1.5
            elide: Text.ElideRight
          }
          Label {
            width: parent.width
            text: picker.role(cardItem.modelData.text)
            color: Theme.foreground
            font.pixelSize: 12
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: pointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPressed: hint.dismiss()
          onClicked: picker.picked(cardItem.modelData.name)
        }
        Hint { id: hint; active: pointer.containsMouse; text: Omunculus.modelOf(cardItem.modelData.name) }
        FocusRing { shown: cardItem.current }
      }
    }

    Label {
      Layout.alignment: Qt.AlignHCenter
      visible: picker.agents.length === 0
      text: Omunculus.setup ? "No agent of depth 0 to talk with." : "reading the project"
      color: Theme.dim
    }
  }
}
