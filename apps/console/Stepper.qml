pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"
import "kit/client/Progress.js" as Progress

// Stepper is a work's stages on one line: done, current and next, in the
// longest form of Progress.stepper that fits its width. The font is
// monospace, so the width is counted in characters; when a glyph still draws
// wider than counted, the line gives back one character, at most three times.
Item {
  id: stepper

  // A Progress node's steps, and its round (0 before any send-back).
  property var steps: []
  property int round: 0
  property real size: 11
  // What the line stands for in words, as its tip: the workflow, the stage.
  property string tip
  property int slack: 0

  readonly property real advance: metrics.advanceWidth("0")
  readonly property int budget: Math.max(1, Math.floor(width / Math.max(1, advance)) - slack)
  readonly property var tokens: steps.length > 0 && width > 0 ? Progress.stepper(steps, round, budget).tokens : []
  readonly property string plain: tokens.map(token => token.text).join("")

  visible: steps.length > 0
  implicitHeight: visible ? metrics.height : 0
  implicitWidth: drawn.advanceWidth
  onWidthChanged: slack = 0
  onStepsChanged: slack = 0
  onRoundChanged: slack = 0

  function check() {
    if (drawn.advanceWidth > width + 0.5 && slack < 3)
      slack++
  }

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: stepper.size }
  TextMetrics {
    id: drawn
    font.family: Theme.fontFamily
    font.pixelSize: stepper.size
    font.bold: true
    text: stepper.plain
    onAdvanceWidthChanged: Qt.callLater(stepper.check)
  }

  Row {
    anchors.verticalCenter: parent.verticalCenter
    Repeater {
      model: stepper.tokens
      delegate: Label {
        required property var modelData
        text: modelData.text
        color: ({ done: Theme.success, current: Theme.primary })[modelData.status] || Theme.dim
        font.pixelSize: stepper.size
        font.bold: modelData.status === "current"
      }
    }
  }

  HoverHandler { id: hover }
  Hint { active: hover.hovered; text: stepper.tip }
  Accessible.role: Accessible.StaticText
  Accessible.name: stepper.tip || stepper.plain
}
