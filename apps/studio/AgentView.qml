pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AgentView is one agent: its depth, the model it runs on, whether it runs
// only as a stage, what it has, may ask for, needs a person for and never
// has, its skills and its text. One a pack brings is read as the setup has
// it; one of the project's own is edited as the file holds it.
ItemPage {
  id: page

  required property Item settings
  required property string name

  // The agent as the setup has it, packs' included.
  readonly property var setupAgent: (Studio.setup ? Studio.setup.agents : []).find(agent => agent.name === name) || null
  readonly property bool own: settings.stored("agents", name) !== null || settings.pending.agents && settings.pending.agents.includes(name)
  readonly property var table: own ? item.draft : setupAgent || {}
  readonly property var held: table[Studio.hasKey(table)] || table.granted || []

  kind: "agent"
  title: own ? item.newName : name
  origin: own ? "" : settings.originOf("agents", name)
  draft: own ? item : null
  facts: [
    ["depth", table.depth === undefined ? "" : String(table.depth)],
    ["model", table.model || ""],
    ["workflow only", table.workflow_only ? "yes" : "no"],
    ["has", held.join(", ")],
    ["asks for", (table.negotiable || []).join(", ")],
    ["a person gives", (table.human || []).join(", ")],
    ["never has", (table.deny || []).join(", ")]
  ]

  ItemDraft {
    id: item
    section: "agents"
    name: page.name
    stored: page.settings.stored("agents", page.name)
    fresh: ({ depth: 1, model: page.settings.listed.models[0] || "", text: "" })
    taken: page.settings.listed.agents
  }

  details: [
    Caption { text: "TEXT" },
    Label {
      Layout.fillWidth: true
      text: page.table.text || ""
      color: Theme.foreground
      font.pixelSize: 12
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
    }
  ]

  RowLayout {
    Layout.fillWidth: true
    spacing: 16
    NumberField {
      Layout.fillWidth: false
      Layout.preferredWidth: 120
      label: "depth"
      number: page.table.depth || 0
      minimum: 0
      onNumberEdited: number => item.put(["depth"], number)
    }
    PickRow {
      text: "MODEL"
      options: page.settings.listed.models
      current: page.table.model || ""
      invalid: !page.settings.listed.models.includes(page.table.model)
      onPicked: model => item.put(["model"], model)
    }
    Chip {
      Layout.alignment: Qt.AlignBottom
      text: "WORKFLOW ONLY"
      tip: "runs only as a stage of a workflow"
      checked: !!page.table.workflow_only
      onClicked: item.put(["workflow_only"], page.table.workflow_only ? null : true)
    }
    Item { Layout.fillWidth: true }
  }
  SettingsTextArea {
    Layout.fillWidth: true
    label: "text"
    lines: 16
    value: page.table.text || ""
    onEdited: text => item.put(["text"], text)
  }
  // Which skills it has: all of them by the skills group, or each on its own.
  ColumnLayout {
    Layout.fillWidth: true
    spacing: 6
    Caption { text: "SKILLS" }
    Flow {
      Layout.fillWidth: true
      spacing: 6
      Chip {
        text: "ALL"
        tip: "every skill of [skills] paths, as they come and go"
        checked: (page.table[Studio.hasKey(page.table)] || []).includes("skills")
        onClicked: item.replace(Studio.withAllSkills(page.table, !checked))
      }
      Repeater {
        model: Studio.skillNames
        delegate: Chip {
          required property string modelData
          text: modelData
          checked: Studio.hasSkill(page.table, modelData)
          onClicked: item.replace(Studio.withSkill(page.table, modelData, !checked))
        }
      }
    }
    Note {
      visible: Studio.skillNames.length === 0
      value: "No skill in [skills] paths."
    }
  }
  CeilingFields {
    Layout.fillWidth: true
    table: page.table
    choices: page.settings.names
    onChanged: table => item.replace(table)
  }
}
