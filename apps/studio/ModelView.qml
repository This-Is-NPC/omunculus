pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ModelView is one model the agents run on: its api, the model's id, the url
// and options sent with every request, or the module or command it is; and
// the agents on it. TEST sends it one short prompt as it is, saved or not.
ItemPage {
  id: page

  required property Item settings
  required property string name

  readonly property var table: item.draft
  readonly property bool http: ["openai-completions", "openai-responses", "anthropic-messages"].includes(table.api)
  readonly property var users: (Studio.setup ? Studio.setup.agents : []).filter(agent => agent.model === name).map(agent => agent.name)
  property bool testing: false
  property string tested: ""
  property bool testFailed: false

  function test() {
    testing = true
    tested = ""
    Studio.testModel(item.newName, table, result => {
      testing = false
      testFailed = false
      tested = "answered in " + (result.ms / 1000).toFixed(1) + " s: " + String(result.reply).replace(/\s+/g, " ").slice(0, 160)
    }, reason => {
      testing = false
      testFailed = true
      tested = reason
    })
  }
  onTableChanged: tested = ""

  related: [
    { title: "PROVIDER", items: table.provider ? [settings.link(0, table.provider)] : [] },
    { title: "AGENTS", items: users.map(agent => settings.link(2, agent)) }
  ]

  kind: "model"
  draft: ItemDraft {
    id: item
    section: "models"
    name: page.name
    stored: page.settings.stored("models", page.name)
    fresh: ({ api: "openai-completions", model: "", url: "", timeout_ms: 120000 })
    taken: page.settings.listed.models
  }
  facts: [
    ["api", table.api || ""],
    [table.api === "module" ? "module" : "model id", table.api === "module" ? table.module || "" : table.model || ""],
    ["provider", table.provider || ""],
    ["url", table.url || ""],
    ["timeout ms", table.timeout_ms === undefined ? "" : String(table.timeout_ms)],
    ["stream", table.stream ? "yes" : "no"],
    ["body", table.body ? JSON.stringify(table.body) : ""],
    ["agents", users.join(", ")]
  ].filter(fact => page.http || !["url", "timeout ms", "stream", "body"].includes(fact[0]))
  extra: [{ text: testing ? "TESTING" : "TEST", icon: "play", tip: "send it one short prompt, as it is here", shown: table.api !== "command",
    enabled: !testing && item.nameIssue === "", run: () => page.test() }]

  details: [
    Label {
      Layout.fillWidth: true
      visible: page.tested !== ""
      text: page.tested
      color: page.testFailed ? Theme.error : Theme.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }
  ]

  RowLayout {
    Layout.fillWidth: true
    spacing: 16
    PickRow {
      text: "API"
      options: ["openai-completions", "openai-responses", "anthropic-messages", "command", "module"]
      current: page.table.api || ""
      onPicked: api => item.put(["api"], api)
    }
    PickRow {
      visible: page.table.api !== "module"
      text: "PROVIDER"
      options: [""].concat(page.settings.listed.auth)
      current: page.table.provider || ""
      describe: provider => provider === "" ? "none" : provider
      invalid: !!page.table.provider && !page.settings.listed.auth.includes(page.table.provider)
      onPicked: provider => item.put(["provider"], provider === "" ? null : provider)
    }
    Item { Layout.fillWidth: true }
  }
  Field {
    Layout.fillWidth: true
    visible: page.table.api !== "module"
    label: "model id"
    value: page.table.model || ""
    onEdited: text => item.put(["model"], text === "" ? null : text)
  }
  Field {
    Layout.fillWidth: true
    visible: page.http
    label: "url"
    value: page.table.url || ""
    onEdited: text => item.put(["url"], text === "" ? null : text)
  }
  RowLayout {
    Layout.fillWidth: true
    visible: page.http
    spacing: 16
    OptionalNumber { draft: item; path: ["timeout_ms"]; Layout.preferredWidth: 160; label: "timeout ms" }
    Chip {
      Layout.alignment: Qt.AlignBottom
      text: "STREAM"
      tip: "read the reply as it is written"
      checked: !!page.table.stream
      onClicked: item.put(["stream"], page.table.stream ? null : true)
    }
    Item { Layout.fillWidth: true }
  }
  BodyFields {
    Layout.fillWidth: true
    visible: page.http
    api: page.table.api || ""
    table: page.table.body || {}
    onChanged: table => item.put(["body"], Object.keys(table).length ? table : null)
  }
  Field {
    Layout.fillWidth: true
    visible: page.table.api === "module"
    label: "module"
    value: page.table.module || ""
    onEdited: text => item.put(["module"], text === "" ? null : text)
  }
  SettingsTextArea {
    Layout.fillWidth: true
    visible: page.table.api === "command"
    label: "command, one argument per line"
    lines: 4
    value: (page.table.command || []).join("\n")
    onEdited: text => item.put(["command"], text.split("\n").filter(line => line !== ""))
  }
  Label {
    Layout.fillWidth: true
    text: page.table.api === "command" ? "A command model runs in the sandbox an agent's ceiling makes; a run tests it." : page.tested
    color: page.testFailed && page.table.api !== "command" ? Theme.error : Theme.dim
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }
}
