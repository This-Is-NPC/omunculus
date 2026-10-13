pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// PolicyView is the project's [policy]: the tool that writes each run's
// prompt, how often a stopped work runs again, how often in a row a broken
// one is sent back, how much output a prompt keeps, the default workspace
// and workflow, and the ceiling of every run.
ItemPage {
  id: page

  required property Item settings

  readonly property var table: item.draft

  related: [
    { title: "DEFAULT WORKSPACE", items: table.workspace ? [settings.link(6, "workspace:" + table.workspace, table.workspace)] : [] },
    { title: "DEFAULT WORKFLOW", items: table.workflow ? [settings.link(3, table.workflow)] : [] }
  ]

  kind: "policy"
  title: "policy"
  draft: ItemDraft {
    id: item
    section: "policy"
    single: true
    stored: page.settings.document.policy || null
  }
  facts: [
    ["assemble", table.assemble || ""],
    ["max retries", table.max_retries === undefined ? "" : String(table.max_retries)],
    ["max reopens", table.max_reopens === undefined ? "no limit" : String(table.max_reopens)],
    ["last run output bytes", table.last_run_output_bytes === undefined ? "" : String(table.last_run_output_bytes)],
    ["tool output bytes", table.tool_output_bytes === undefined ? "" : String(table.tool_output_bytes)],
    ["default workspace", table.workspace || "the project root"],
    ["default workflow", table.workflow || "none"],
    ["has", (table.granted || table.tools || []).join(", ")],
    ["never has", (table.deny || []).join(", ")]
  ]

  Field {
    Layout.fillWidth: true
    label: "assemble"
    value: page.table.assemble || ""
    onEdited: text => item.put(["assemble"], text === "" ? null : text)
  }
  Note { value: "The tool that writes each run's prompt." }
  RowLayout {
    Layout.fillWidth: true
    spacing: 16
    OptionalNumber { draft: item; path: ["max_retries"]; Layout.preferredWidth: 140; label: "max retries" }
    OptionalNumber { draft: item; path: ["max_reopens"]; Layout.preferredWidth: 140; label: "max reopens" }
    OptionalNumber { draft: item; path: ["last_run_output_bytes"]; Layout.preferredWidth: 180; label: "last run output bytes" }
    OptionalNumber { draft: item; path: ["tool_output_bytes"]; Layout.preferredWidth: 180; label: "tool output bytes" }
    Item { Layout.fillWidth: true }
  }
  Note { value: "How often a work whose model stopped without a report runs again, how many times in a row a parent may send a broken work back before it asks along its route instead (unset, no limit), and how much of each output a prompt keeps." }
  RowLayout {
    Layout.fillWidth: true
    spacing: 16
    PickRow {
      text: "DEFAULT WORKSPACE"
      options: [""].concat(page.settings.keysOf("workspaces"))
      current: page.table.workspace || ""
      describe: workspace => workspace === "" ? "the project root" : workspace
      onPicked: workspace => item.put(["workspace"], workspace === "" ? null : workspace)
    }
    PickRow {
      text: "DEFAULT WORKFLOW"
      options: [""].concat(page.settings.keysOf("workflows"))
      current: page.table.workflow || ""
      describe: workflow => workflow === "" ? "none" : workflow
      onPicked: workflow => item.put(["workflow"], workflow === "" ? null : workflow)
    }
    Item { Layout.fillWidth: true }
  }
  Caption { text: "CEILING OF EVERY RUN" }
  CeilingFields {
    Layout.fillWidth: true
    table: page.table
    choices: page.settings.names
    onChanged: table => item.replace(table)
  }
}
