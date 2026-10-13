pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkflowView is one workflow: the stages a work goes through, in order,
// each run by its agent, and what a stage never has. One a pack brings is
// read as the setup has it; one of the project's own is edited.
ItemPage {
  id: page

  required property Item settings
  required property string name

  readonly property var setupFlow: (Studio.setup ? Studio.setup.workflows : []).find(flow => flow.name === name) || null
  readonly property bool own: settings.stored("workflows", name) !== null || settings.pending.workflows && settings.pending.workflows.includes(name)
  readonly property var steps: own ? item.draft.steps || [] : setupFlow ? setupFlow.steps : []

  function changed(index, key, value) {
    const next = JSON.parse(JSON.stringify(steps))
    if (value === null || (Array.isArray(value) && value.length === 0))
      delete next[index][key]
    else
      next[index][key] = value
    item.put(["steps"], next)
  }

  kind: "workflow"
  title: own ? item.newName : name
  origin: own ? "" : settings.originOf("workflows", name)
  draft: own ? item : null
  facts: steps.map((step, index) => [String(index + 1).padStart(2, "0") + " " + step.name,
    step.agent + ((step.deny || []).length ? "  ·  never " + step.deny.join(", ") : "")])

  ItemDraft {
    id: item
    section: "workflows"
    name: page.name
    stored: page.settings.stored("workflows", page.name)
    fresh: ({ steps: [{ name: "to_do", agent: page.settings.listed.agents[0] || "" }] })
    taken: page.settings.listed.workflows
  }

  Repeater {
    model: page.steps.length
    delegate: SurfaceFrame {
      id: stage
      required property int index
      readonly property var step: page.steps[index] || {}
      Layout.fillWidth: true
      implicitHeight: stageBody.implicitHeight + 20
      ColumnLayout {
        id: stageBody
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
        spacing: 10
        RowLayout {
          Layout.fillWidth: true
          spacing: 12
          Label { text: String(stage.index + 1).padStart(2, "0"); color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 1 }
          Field {
            Layout.fillWidth: true
            label: "stage"
            value: stage.step.name || ""
            onEdited: text => page.changed(stage.index, "name", text)
          }
          PickRow {
            text: "AGENT"
            options: page.settings.allAgents
            current: stage.step.agent || ""
            invalid: !page.settings.allAgents.includes(stage.step.agent)
            onPicked: agent => page.changed(stage.index, "agent", agent)
          }
          IconButton {
            enabled: stage.index > 0
            opacity: enabled ? 1 : 0.3
            name: "chevron-up"
            tip: "move up"
            onClicked: {
              const next = JSON.parse(JSON.stringify(page.steps))
              next.splice(stage.index - 1, 0, next.splice(stage.index, 1)[0])
              item.put(["steps"], next)
            }
          }
          IconButton {
            name: "close"
            tone: Theme.error
            tip: "remove the stage"
            onClicked: item.put(["steps"], page.steps.filter((_, at) => at !== stage.index))
          }
        }
        NameSet {
          Layout.fillWidth: true
          label: "never has in this stage"
          items: stage.step.deny || []
          choices: page.settings.names
          onChanged: items => page.changed(stage.index, "deny", items)
        }
      }
    }
  }
  Chip {
    text: "ADD STAGE"
    icon: "plus"
    onClicked: item.put(["steps"], page.steps.concat([{ name: "stage_" + (page.steps.length + 1), agent: page.settings.listed.agents[0] || "" }]))
  }
}
