pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// SkillView is one skill of [skills] paths: what it is for, its folder, and
// every agent of the project's own, lit while it has the skill, given it or
// not with a click, which saves that agent.
ItemPage {
  id: page

  required property Item settings
  // The catalog's entry, its name "skill.<name>".
  required property var entry
  readonly property string skill: entry.name.slice(6)

  related: [
    { title: "AGENTS", items: Studio.holders(entry.name).map(agent => settings.link(2, agent)) },
    { title: "TOOLS IT USES", items: (entry.uses || []).map(tool => settings.link(4, tool)) }
  ]

  kind: "skill"
  title: skill
  facts: [
    ["folder", entry.dir || ""],
    ["had by", Studio.holders(entry.name).join(", ")]
  ]
  details: [
    Label {
      Layout.fillWidth: true
      text: page.entry.description || ""
      color: Theme.foreground
      font.pixelSize: 12
      wrapMode: Text.Wrap
    },
    Caption { text: "GIVE IT TO" },
    Note {
      visible: page.settings.keysOf("agents").length === 0
      value: "The project has no agents of its own to give it to; those a pack brings take their skills from the pack."
    },
    Flow {
      Layout.fillWidth: true
      spacing: 6
      Repeater {
        model: page.settings.keysOf("agents").sort()
        delegate: Chip {
          required property string modelData
          readonly property var table: page.settings.document.agents[modelData]
          text: modelData
          checked: Studio.hasSkill(table, page.skill)
          tip: checked ? "take " + page.skill + " from " + modelData : "give " + page.skill + " to " + modelData
          onClicked: {
            const giving = !checked
            const agent = modelData
            Studio.configure("agents." + agent, Studio.withSkill(table, page.skill, giving), "",
              () => Studio.tell((giving ? "gave " + page.skill + " to " : "took " + page.skill + " from ") + agent, false),
              reason => Studio.tell(reason, true))
          }
        }
      }
    }
  ]
}
