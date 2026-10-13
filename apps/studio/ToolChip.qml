import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ToolChip is one name an agent's layer lists, as the ceiling has it where the
// agent runs: had, asked of the agent above (dim), asked of you (warning), or
// taken away there (struck in the error colour). A group reads as the best its
// members have and says how many it holds; a tool with secrets of its own
// carries a key with each provider bound to it.
Rectangle {
  id: chip

  required property var tool

  readonly property bool group: !!tool.members
  readonly property var secrets: Object.keys(tool.secrets || {})
  readonly property color ink: tool.state === "blocked" ? Theme.error
    : tool.state === "sealed" ? Theme.warning
    : tool.state === "askable" ? Theme.dim
    : Theme.secondary
  readonly property string tipText: (tool.state === "blocked" ? "taken away here"
      : tool.state === "sealed" ? "asks you"
      : tool.state === "askable" ? "asks the agent above"
      : "has it")
    + (group ? "  ·  group: " + tool.members.join(", ") : "")
    + secrets.map(name => "\n" + name + " ← " + tool.secrets[name] + "  ·  read from /run/secrets/" + name).join("")

  implicitWidth: row.implicitWidth + 12
  implicitHeight: 18
  color: "transparent"
  border.color: Qt.alpha(ink, secrets.length ? 0.6 : 0.35)

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: 5
    Label {
      text: chip.tool.name
      color: chip.ink
      font.pixelSize: 10
      font.strikeout: chip.tool.state === "blocked"
    }
    Label {
      visible: chip.group
      text: "·" + (chip.tool.members || []).length
      color: Theme.dim
      font.pixelSize: 9
    }
    Repeater {
      model: chip.secrets
      delegate: RowLayout {
        id: secret
        required property string modelData
        spacing: 3
        Rectangle { implicitWidth: 1; implicitHeight: 10; color: Qt.alpha(Theme.primary, 0.4) }
        Icon { name: "key"; size: 10; color: chip.tool.state === "blocked" ? Theme.error : Theme.primary }
        Label { text: chip.tool.secrets[secret.modelData]; color: Theme.primary; font.pixelSize: 9 }
      }
    }
  }

  MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true }
  Hint { visible: pointer.containsMouse; text: chip.tipText }
}
