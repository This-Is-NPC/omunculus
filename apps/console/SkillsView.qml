pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// SkillsView is the skills of the project on screen, read from its [skills]
// paths: each with what it is for and its folder, and every agent of the
// project, lit while it has the skill, given it or not with a click.
ScrollPage {
  id: scroll

  readonly property var catalog: Omunculus.catalog
  readonly property var skills: catalog ? catalog.tools.filter(entry => entry.kind === "skill") : []
  readonly property var document: Omunculus.setup ? Omunculus.setup.document : null
  readonly property var agents: document ? Object.keys(document.agents || {}).sort() : []

  contentHeight: content.implicitHeight

  ColumnLayout {
    id: content
    width: scroll.width
    spacing: 8

    Label {
      Layout.fillWidth: true
      text: scroll.catalog === null ? (Omunculus.connected ? "reading the catalog" : "the server does not answer")
        : scroll.skills.length ? "Read from [skills] paths. An agent has them through the skills group, or one as skill.<name>, and reads one with the skill tool."
        : "No skill in [skills] paths."
      color: Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    Repeater {
      model: scroll.skills
      delegate: ColumnLayout {
        id: skill
        required property var modelData
        readonly property string name: modelData.name.slice(6)
        Layout.fillWidth: true
        spacing: 0

        CatalogEntry {
          Layout.fillWidth: true
          entry: skill.modelData
          note: skill.modelData.dir
        }
        // Each agent, lit while it has the skill; a click gives or takes it and saves the agent.
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: givers.implicitHeight + 14
          color: "transparent"
          border.color: Theme.line
          Flow {
            id: givers
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
            spacing: 6
            Label { text: "AGENTS"; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2; height: 22; verticalAlignment: Text.AlignVCenter }
            Repeater {
              model: scroll.agents
              delegate: Chip {
                required property string modelData
                readonly property var table: scroll.document.agents[modelData]
                text: modelData
                checked: Omunculus.hasSkill(table, skill.name)
                tip: checked ? "take " + skill.name + " from " + modelData : "give " + skill.name + " to " + modelData
                onClicked: {
                  const giving = !checked
                  const agent = modelData
                  Omunculus.configure("agents." + agent, Omunculus.withSkill(table, skill.name, giving), "",
                    () => Omunculus.tell((giving ? "gave " + skill.name + " to " : "took " + skill.name + " from ") + agent, false),
                    reason => Omunculus.tell(reason, true))
                }
              }
            }
          }
        }
      }
    }
  }
}
