pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AccessView is the project's [access]: who may do what, by role, the role a
// conversation's creator takes and the one of the first administrator; and
// the project's members, each with its role, who can be added and removed
// as the server allows.
ItemPage {
  id: page

  required property Item settings

  readonly property var table: item.draft
  readonly property var roles: table.roles || {}
  readonly property var capabilities: ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read",
    "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

  // The roles a project member may take.
  readonly property var memberRoles: Object.keys(roles).filter(role => roles[role].scope === "project")
  property string newRole: memberRoles[0] || ""

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

  Kicker { Layout.fillWidth: true; text: "members" }
  Note { value: Studio.members === null ? "The members are listed to those who manage the project's access." : "Who holds a project role. A role named here applies to every conversation." }
  Repeater {
    model: Studio.members || []
    delegate: SurfaceFrame {
      id: member
      required property var modelData
      Layout.fillWidth: true
      implicitHeight: memberRow.implicitHeight + 20
      RowLayout {
        id: memberRow
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
        spacing: 12
        Label { text: member.modelData.issuer; color: Theme.dim; font.pixelSize: 12 }
        Label { Layout.fillWidth: true; text: member.modelData.subject; font.pixelSize: 12; elide: Text.ElideRight }
        Label { text: member.modelData.role; color: Theme.primary; font.pixelSize: 12 }
        IconButton {
          name: "close"
          tone: Theme.error
          tip: "remove the member"
          onClicked: Studio.setMember(member.modelData.issuer, member.modelData.subject, null, () => {}, reason => Studio.tell(reason, true))
        }
      }
    }
  }
  RowLayout {
    Layout.fillWidth: true
    visible: Studio.members !== null
    spacing: 12
    Field { id: issuer; Layout.fillWidth: true; label: "issuer" }
    Field { id: subject; Layout.fillWidth: true; label: "subject" }
    PickRow {
      text: "ROLE"
      options: page.memberRoles
      current: page.newRole
      onPicked: role => page.newRole = role
    }
    Chip {
      Layout.alignment: Qt.AlignBottom
      text: "ADD MEMBER"
      icon: "plus"
      reason: issuer.input.text.trim() === "" || subject.input.text.trim() === "" || page.newRole === "" ? "name the issuer, the subject and a project role" : ""
      onClicked: Studio.setMember(issuer.input.text.trim(), subject.input.text.trim(), page.newRole, () => {
        issuer.input.text = ""
        subject.input.text = ""
      }, reason => Studio.tell(reason, true))
    }
  }
}
