import QtQuick
import QtQuick.Layouts
import "kit/ui"

// SkillCard is one skill an agent has in a place of the overview: its name, as
// the ceiling has it there, and the tools its allowed-tools names, each in the
// warning colour when the agent does not have it there. Its description shows
// on hover.
Rectangle {
  id: card

  required property var skill
  // Whether the agent has the tool `name` here.
  property var had: name => false

  readonly property color ink: skill.state === "sealed" ? Theme.warning : skill.state === "askable" ? Theme.dim : Theme.primary

  implicitWidth: Math.min(240, column.implicitWidth + 16)
  implicitHeight: column.implicitHeight + 10
  color: Qt.alpha(Theme.primary, 0.05)
  border.color: Qt.alpha(ink, 0.5)

  ColumnLayout {
    id: column
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 8 }
    spacing: 2
    Label { text: card.skill.name; color: card.ink; font.pixelSize: 11 }
    Label {
      Layout.fillWidth: true
      visible: card.skill.uses.length > 0
      text: "uses " + card.skill.uses.map(name => card.had(name) ? name : name + " (not here)").join(", ")
      color: card.skill.uses.every(name => card.had(name)) ? Theme.dim : Theme.warning
      font.pixelSize: 9
      elide: Text.ElideRight
    }
  }

  MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
  Hint { visible: pointer.containsMouse; text: card.skill.description }
}
