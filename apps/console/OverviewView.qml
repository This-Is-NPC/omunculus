pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// OverviewView is every project of the server, one under the other, each as it
// runs in each of its workspaces. Picking an agent of the project on screen
// opens it where it is edited.
ScrollPage {
  id: scroll

  signal agentPicked(string name)

  contentHeight: content.implicitHeight

  ColumnLayout {
    id: content
    width: scroll.width
    spacing: 16

    Label {
      Layout.fillWidth: true
      text: "Each project as it runs: its depths are lanes, each workspace a band across them. A name struck out is taken away there; one in the warning colour asks you; a key marks a tool with secrets of its own."
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    Repeater {
      model: Omunculus.projects
      delegate: ProjectOverview {
        required property var modelData
        Layout.fillWidth: true
        projectId: modelData.id
        overview: Omunculus.overviews[modelData.id]
        onAgentPicked: name => { if (modelData.id === Omunculus.project) scroll.agentPicked(name) }
      }
    }
  }
}
