pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ToolsView is the tools of the project on screen, each with where it comes
// from, its triggers, groups, the secrets it declares, bound or not, and the
// agents that have it; and the MCP servers the config starts, whose tools a run
// lists.
ScrollPage {
  id: scroll

  readonly property var catalog: Omunculus.catalog
  readonly property var entries: catalog ? catalog.tools : []
  readonly property var tools: entries.filter(entry => entry.kind !== "skill")
  contentHeight: content.implicitHeight

  ColumnLayout {
    id: content
    width: scroll.width
    spacing: 16

    Label {
      visible: scroll.catalog === null
      text: Omunculus.connected ? "reading the catalog" : "the server does not answer"
      color: Theme.dim
    }

    Panel {
      Layout.fillWidth: true
      Layout.preferredHeight: implicitHeight
      visible: scroll.catalog !== null
      index: "01"
      title: "tools"
      ColumnLayout {
        anchors.fill: parent
        spacing: 8
        Repeater {
          model: scroll.tools
          delegate: CatalogEntry {
            required property var modelData
            Layout.fillWidth: true
            entry: modelData
            note: modelData.source === "inline" ? "inline in the project's config" : modelData.dir
            agents: modelData.triggers.includes("model") ? Omunculus.holders(modelData.name) : []
          }
        }
      }
    }

    Panel {
      Layout.fillWidth: true
      Layout.preferredHeight: implicitHeight
      visible: scroll.catalog !== null
      index: "02"
      title: "mcp servers"
      ColumnLayout {
        anchors.fill: parent
        spacing: 8
        Label {
          visible: !!scroll.catalog && scroll.catalog.mcp.length === 0
          text: "No [[mcp.servers]]."
          color: Theme.dim
          font.pixelSize: 11
        }
        Repeater {
          model: scroll.catalog ? scroll.catalog.mcp : []
          delegate: CatalogEntry {
            required property var modelData
            Layout.fillWidth: true
            entry: ({ name: modelData.name, kind: "mcp server", description: "", triggers: [], groups: [],
              secrets: Object.keys(modelData.secrets), binding: modelData.secrets })
            note: modelData.command.join(" ")
            agents: []
          }
        }
      }
    }
  }
}
