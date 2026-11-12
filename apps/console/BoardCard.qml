import QtQuick
import QtQuick.Layouts
import "kit/ui"

// BoardCard is one work on the board, framed as a list row: its title, and
// at the top right how long since it last changed; under it the agent it is
// with (AgentName), its level and the work it hangs under, the project and,
// in a workflow, the stage it is at; its state (StateMark) with, at the
// right, the conversation it is in. A work that is done or cancelled steps back. The keyboard
// reaches it; Enter or Space, or a click, opens it.
Rectangle {
  id: card

  required property var work
  // What the board says of it: the meta line and the lineage under its title,
  // its state as {state, text}, the conversation, its age, and whether an
  // agent runs on it now.
  required property string meta
  required property string lineage
  required property var mark
  required property string origin
  required property string age
  required property bool running
  signal opened()

  implicitHeight: details.implicitHeight + Theme.space.cell * 2
  activeFocusOnTab: true
  Keys.onReturnPressed: opened()
  Keys.onSpacePressed: opened()
  color: activeFocus ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
  border.color: activeFocus || running ? Theme.primary : Theme.line
  opacity: work.state === "done" || work.state === "cancelled" ? 0.4 : 1
  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on border.color { ColorAnimation { duration: 200 } }

  ColumnLayout {
    id: details
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.cell }
    spacing: Theme.space.tight

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      Label {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        text: card.work.title
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Label {
        Layout.alignment: Qt.AlignTop
        text: card.age
        color: Theme.dim
        font.pixelSize: Theme.type.header.size
        font.letterSpacing: Theme.type.header.tracking
      }
    }
    AgentName {
      name: Omunculus.agentOf(card.work)
      tone: Omunculus.toneOf(name, card.work.project)
      limit: parent.width
    }
    Label {
      Layout.fillWidth: true
      text: [card.lineage, card.meta].filter(part => part !== "").join(Theme.type.meta.separator)
      color: Theme.dim
      font.pixelSize: Theme.type.meta.size
      elide: Text.ElideRight
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      StateMark {
        state: card.mark.state
        text: card.mark.text
      }
      Item { Layout.fillWidth: true }
      Label {
        text: card.origin
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        elide: Text.ElideRight
        Layout.maximumWidth: card.width / 2
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
