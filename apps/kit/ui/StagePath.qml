pragma ComponentBehavior: Bound
import QtQuick

// StagePath is a workflow's stages on one line that wraps when the width is
// short: done ✓ in the success tone, the current one ● in the accent and bold,
// those to come ○ dim, each name in capitals, joined by hairlines. Used in a
// work's row of the hierarchy and under a log line.
Flow {
  id: path

  // [{name, status}] with status done, current or next, as Progress.trail and
  // a Progress node's `steps` give.
  property var stages: []
  property real size: Theme.type.log.size

  readonly property var glyphs: ({ done: "✓", current: "●", next: "○" })

  visible: stages.length > 0
  spacing: Theme.space.line
  Accessible.role: Accessible.StaticText
  Accessible.name: stages.map(stage => stage.name + " " + stage.status).join(", ")

  Repeater {
    model: path.stages
    delegate: Row {
      id: stage
      required property var modelData
      required property int index
      spacing: Theme.space.tight
      Rectangle {
        visible: stage.index > 0
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.size.gutter
        height: 1
        color: Theme.faint
      }
      Label {
        text: path.glyphs[stage.modelData.status] + " " + stage.modelData.name.toUpperCase()
        color: ({ done: Theme.success, current: Theme.primary })[stage.modelData.status] || Theme.dim
        font.pixelSize: path.size
        font.letterSpacing: Theme.type.header.tracking
        font.bold: stage.modelData.status === "current"
      }
    }
  }
}
