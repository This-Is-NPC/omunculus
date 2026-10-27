pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// ProjectFilter narrows the list to one project, or shows every project, as
// a strip of chips.
Flow {
  id: filter
  spacing: 6
  visible: Mail.projects.length > 1
  Repeater {
    model: [""].concat(Mail.projects.map(place => place.id))
    delegate: Chip {
      required property string modelData
      checked: Mail.project === modelData
      text: modelData === "" ? "ALL PROJECTS" : modelData.toUpperCase()
      onClicked: Mail.project = modelData
    }
  }
}
