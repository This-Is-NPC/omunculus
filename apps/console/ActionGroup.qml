import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ActionGroup holds the actions of one pending item, together under a
// hairline: its buttons wrap inside the item at any width, each whole.
ColumnLayout {
  id: group

  // What the group is for, read out as its name.
  property string label: "actions"
  default property alias actions: flow.data

  Layout.fillWidth: true
  spacing: Theme.space.gap
  Accessible.role: Accessible.Grouping
  Accessible.name: group.label

  Rectangle {
    Layout.fillWidth: true
    implicitHeight: 1
    color: Theme.line
  }
  Flow {
    id: flow
    Layout.fillWidth: true
    spacing: Theme.space.tight
  }
}
