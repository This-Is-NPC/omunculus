pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AccessView is the project's [access]: who may do what, by role, the role a
// conversation's creator takes and the one of the first administrator. The
// members of each role are in the store, not here.
ItemPage {
  id: page

  required property Item settings

  readonly property var table: item.draft
  readonly property var roles: table.roles || {}
  readonly property var capabilities: ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read",
    "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

  function renamed(from, to) {
    const next = {}
    for (const key of Object.keys(roles))
      next[key === from ? to : key] = roles[key]
    item.put(["roles"], next)
  }

  kind: "access"
  title: "access"
  draft: ItemDraft {
    id: item
    section: "access"
    single: true
    stored: page.settings.document.access || null
  }
  facts: [
    ["a conversation's creator", table.creator_role || ""],
    ["the first administrator", table.bootstrap_role || ""]
  ].concat(Object.keys(roles).map(role => [role + " · " + (roles[role].scope || ""), (roles[role].capabilities || []).join(", ")]))

  RowLayout {
    Layout.fillWidth: true
    spacing: 16
    PickRow {
      text: "A CONVERSATION'S CREATOR"
      options: Object.keys(page.roles)
      current: page.table.creator_role || ""
      onPicked: role => item.put(["creator_role"], role)
    }
    PickRow {
      text: "THE FIRST ADMINISTRATOR"
      options: Object.keys(page.roles)
      current: page.table.bootstrap_role || ""
      onPicked: role => item.put(["bootstrap_role"], role)
    }
    Item { Layout.fillWidth: true }
  }
  Repeater {
    model: Object.keys(page.roles).length
    delegate: SurfaceFrame {
      id: role
      required property int index
      readonly property string roleName: Object.keys(page.roles)[index] || ""
      readonly property var entry: page.roles[roleName] || {}
      Layout.fillWidth: true
      implicitHeight: roleBody.implicitHeight + 20
      ColumnLayout {
        id: roleBody
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
        spacing: 10
        RowLayout {
          Layout.fillWidth: true
          spacing: 12
          Field {
            Layout.fillWidth: true
            label: "role"
            value: role.roleName
            onCommitted: text => {
              const name = text.trim()
              if (/^[A-Za-z0-9_-]+$/.test(name) && page.roles[name] === undefined)
                page.renamed(role.roleName, name)
            }
          }
          PickRow {
            text: "SCOPE"
            options: ["project", "conversation"]
            current: role.entry.scope || ""
            onPicked: scope => item.put(["roles", role.roleName, "scope"], scope)
          }
          IconButton {
            name: "close"
            tone: Theme.error
            tip: "remove the role"
            onClicked: item.put(["roles", role.roleName], null)
          }
        }
        NameSet {
          Layout.fillWidth: true
          label: "capabilities"
          items: role.entry.capabilities || []
          choices: page.capabilities
          closed: true
          onChanged: items => item.put(["roles", role.roleName, "capabilities"], items)
        }
      }
    }
  }
  Chip {
    text: "ADD ROLE"
    icon: "plus"
    onClicked: {
      let name = "role"
      for (let n = 2; page.roles[name] !== undefined; n++)
        name = "role_" + n
      item.put(["roles", name], { scope: "conversation", capabilities: ["conversation.read"] })
    }
  }
}
