pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkspaceView is one workspace: the directory the agents work in there,
// relative to the project root, and the ceiling that holds there.
ItemPage {
  id: page

  required property Item settings
  required property string name

  readonly property var table: item.draft

  related: [
    { title: "POLICY", items: Studio.setup && Studio.setup.workspace === name ? [settings.link(6, "policy", "policy, its default")] : [] }
  ]

  kind: "workspace"
  draft: ItemDraft {
    id: item
    section: "workspaces"
    name: page.name
    stored: page.settings.stored("workspaces", page.name)
    fresh: ({ root: "." })
    taken: page.settings.listed.workspaces
  }
  facts: [
    ["root", table.root || ""],
    ["default", Studio.setup && Studio.setup.workspace === name ? "yes" : "no"],
    ["has", (table.granted || table.tools || []).join(", ")],
    ["asks for", (table.negotiable || []).join(", ")],
    ["a person gives", (table.human || []).join(", ")],
    ["never has", (table.deny || []).join(", ")]
  ]

  Field {
    Layout.fillWidth: true
    label: "root"
    value: page.table.root || ""
    onEdited: text => item.put(["root"], text)
  }
  CeilingFields {
    Layout.fillWidth: true
    table: page.table
    choices: page.settings.names
    onChanged: table => item.replace(table)
  }
}
