pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// CatalogEntry is one entry of the catalog: its name and kind, what it is for,
// where it comes from, its triggers and groups, its secrets with the provider
// bound to each (a key) or none (a warning), and the agents that have it.
Rectangle {
  id: row
  required property var entry
  property string note
  property var agents: []

  implicitHeight: lines.implicitHeight + 16
  color: "transparent"
  border.color: Theme.line

  ColumnLayout {
    id: lines
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8; leftMargin: 12; rightMargin: 12 }
    spacing: 4

    Flow {
      Layout.fillWidth: true
      spacing: 8
      Label { text: row.entry.name; color: Theme.foreground; font.pixelSize: 12 }
      Label { text: row.entry.kind; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2 }
      Repeater {
        model: row.entry.triggers
        delegate: ToolChip {
          required property string modelData
          tool: ({ name: modelData, state: "askable" })
        }
      }
      Repeater {
        model: row.entry.groups
        delegate: ToolChip {
          required property string modelData
          tool: ({ name: modelData, state: "have" })
        }
      }
      Repeater {
        model: row.entry.secrets
        delegate: ToolChip {
          required property string modelData
          readonly property string provider: (row.entry.binding || {})[modelData] || ""
          tool: provider ? ({ name: modelData, state: "have", secrets: { [modelData]: provider } })
            : ({ name: modelData + " unbound", state: "sealed" })
        }
      }
    }
    Label {
      Layout.fillWidth: true
      visible: row.entry.description !== ""
      text: row.entry.description
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }
    Label {
      Layout.fillWidth: true
      text: row.note
      color: Theme.line
      font.pixelSize: 10
      elide: Text.ElideMiddle
    }
    Flow {
      Layout.fillWidth: true
      visible: row.agents.length > 0
      spacing: 6
      Label { text: "HAD BY"; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2 }
      Repeater {
        model: row.agents
        delegate: Label {
          required property string modelData
          text: modelData
          color: Studio.toneOf(modelData)
          font.pixelSize: 11
        }
      }
    }
  }
}
