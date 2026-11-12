pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// StagePath is a workflow's stages on one line that wraps when the width is
// short: done ✓ in the success tone, the current one ● in the accent and bold,
// those to come ○ dim, joined by "›".
Flow {
  id: path

  // [{name, status}] with status done, current or next, as Progress.trail gives.
  property var stages: []
  property real size: Theme.type.log.size

  readonly property var glyphs: ({ done: "✓", current: "●", next: "○" })

  visible: stages.length > 0
  Accessible.role: Accessible.StaticText
  Accessible.name: stages.map(stage => stage.name + " " + stage.status).join(", ")

  Repeater {
    model: path.stages
    delegate: Label {
      required property var modelData
      required property int index
      text: (index > 0 ? " › " : "") + path.glyphs[modelData.status] + " " + modelData.name
      color: ({ done: Theme.success, current: Theme.primary })[modelData.status] || Theme.dim
      font.pixelSize: path.size
      font.bold: modelData.status === "current"
    }
  }
}
