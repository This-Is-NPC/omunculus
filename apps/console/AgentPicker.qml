pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AgentPicker is whom a new conversation is with: a card for each agent of
// depth 0 that is not only in workflows — its portrait, its name in its
// colour, the model it runs on and the first sentence of its text. A click,
// Enter, or its number starts the conversation with it; Esc goes back.
FocusScope {
  id: picker

  signal picked(string name)
  signal back()

  readonly property var agents: Omunculus.talkable
  readonly property real card: 220

  Keys.onEscapePressed: back()
  Keys.onPressed: event => {
    const index = event.key - Qt.Key_1
    if (index >= 0 && index < Math.min(9, agents.length)) {
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
      cellHeight: picker.card + 110
      clip: true
      focus: true
      keyNavigationEnabled: true
      model: picker.agents
      Keys.onReturnPressed: if (currentItem) picker.picked(picker.agents[currentIndex].name)
      Keys.onEnterPressed: if (currentItem) picker.picked(picker.agents[currentIndex].name)

      delegate: Rectangle {
        id: cardItem
        required property var modelData
        required property int index
        readonly property bool current: GridView.isCurrentItem && grid.activeFocus
        width: picker.card
        height: picker.card + 94
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
            text: Omunculus.modelOf(cardItem.modelData.name)
            color: Theme.dim
            font.pixelSize: 10
            elide: Text.ElideMiddle
          }
          Label {
            width: parent.width
            text: (cardItem.modelData.text || "").split(/[.:\n]/)[0]
            color: Theme.foreground
            opacity: 0.8
            font.pixelSize: 10
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
        }

        MouseArea {
          id: pointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: picker.picked(cardItem.modelData.name)
        }
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
