pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// ScopeBar says which branch of the hierarchy a view is kept to: SCOPE, the
// agents from the front desk down to the work's, each in its tone, and its
// level; and the way back out, WHOLE CONVERSATION, which emits wholeWanted().
// `trail` is [{agent, tone}] from the top; `level` the work's depth.
SurfaceFrame {
  id: bar

  property var trail: []
  property int level: 0
  signal wholeWanted()

  implicitHeight: content.implicitHeight + Theme.space.gap * 2
  variant: "outline"

  RowLayout {
    id: content
    x: Theme.space.inset
    y: Theme.space.gap
    width: parent.width - Theme.space.inset * 2
    spacing: Theme.space.gap

    Label {
      text: "SCOPE"
      color: Theme.dim
      font.pixelSize: Theme.type.kicker.size
      font.letterSpacing: Theme.type.kicker.tracking
    }
    Flow {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      spacing: Theme.space.tight
      Repeater {
        model: bar.trail
        delegate: Row {
          id: step
          required property var modelData
          required property int index
          spacing: Theme.space.tight
          Label { visible: step.index > 0; text: "›"; color: Theme.faint; font.pixelSize: Theme.type.log.size }
          AgentName { name: step.modelData.agent; tone: step.modelData.tone }
          Label { visible: step.index === bar.trail.length - 1; text: "(level " + bar.level + ")"; color: Theme.dim; font.pixelSize: Theme.type.log.size }
        }
      }
    }
    TraceButton {
      role: "action"
      dense: true
      text: "WHOLE CONVERSATION"
      tip: "back to every work"
      onClicked: bar.wholeWanted()
    }
  }
}
