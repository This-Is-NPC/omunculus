pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// ProjectFilter narrows the list to one project, or shows every project.
Flow {
  id: filter
  spacing: 6
  visible: Mail.projects.length > 1
  Repeater {
    model: [""].concat(Mail.projects.map(place => place.id))
    delegate: Rectangle {
      id: choice
      required property string modelData
      readonly property bool chosen: Mail.project === modelData
      implicitWidth: label.implicitWidth + 16
      implicitHeight: 22
      color: chosen ? Qt.alpha(Theme.primary, 0.12) : "transparent"
      border.color: chosen ? Theme.primary : Theme.line
      Label {
        id: label
        anchors.centerIn: parent
        text: choice.modelData === "" ? "ALL PROJECTS" : choice.modelData.toUpperCase()
        color: choice.chosen ? Theme.primary : Theme.dim
        font.pixelSize: 9
        font.letterSpacing: 1.5
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Mail.project = choice.modelData }
    }
  }
}
