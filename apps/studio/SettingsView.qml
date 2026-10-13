pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// SettingsView shapes the project's config in the order its parts depend on
// each other: the secrets of the providers, the models that use them, the
// agents on those models, the workflows of those agents, the tools and the
// skills of the catalog, and the project's own policy, workspaces and
// access, one section at a time. Each item is edited and saved on its own, through the configure tool, which writes it only
// if the result loads. Nothing applies before it is saved; the next run reads it.
Item {
  id: view

  property bool active: false
  // The section on screen: secrets, models, agents, workflows, tools,
  // skills or the project, 0 to 6.
  property int page: 0
  // A section asked for, as when an item of another is revealed.
  signal wanted(int page)
  // Section -> names added here and not saved yet.
  property var pending: ({})
  // Section/name -> whether its card is open.
  property var opened: ({})
  // The agent on its own screen, or "".
  property string agent: ""
  // The names of each section, replaced only when they change, so that the
  // cards are not made again when the file is read again.
  property var listed: ({ auth: [], models: [], agents: [], workflows: [], workspaces: [] })
  // What a removal asks to remove: [section, name].
  property var removal: null

  readonly property var document: Studio.setup ? Studio.setup.document : null
  readonly property var names: Studio.setup ? Studio.setup.names : []
  readonly property var literalKeys: Studio.setup ? Studio.setup.literal_keys : []
  readonly property var capabilities: ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read",
    "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

  function stored(section, name) {
    return document && document[section] && document[section][name] !== undefined ? document[section][name] : null
  }
  function keysOf(section) { return document && document[section] ? Object.keys(document[section]) : [] }

  function relist() {
    const next = {}
    const kept = {}
    for (const section of Object.keys(listed)) {
      const saved = keysOf(section)
      kept[section] = (pending[section] || []).filter(name => !saved.includes(name))
      next[section] = saved.concat(kept[section])
    }
    if (JSON.stringify(kept) !== JSON.stringify(pending))
      pending = kept
    if (JSON.stringify(next) !== JSON.stringify(listed))
      listed = next
  }
  onDocumentChanged: relist()

  // Adds a new item, not saved yet, and opens it.
  function add(section, stem) {
    let name = stem
    for (let n = 2; listed[section].includes(name); n++)
      name = stem + "_" + n
    pending = Object.assign({}, pending, { [section]: (pending[section] || []).concat([name]) })
    relist()
    open(section, name)
    return name
  }
  function drop(section, name) {
    pending = Object.assign({}, pending, { [section]: (pending[section] || []).filter(item => item !== name) })
    relist()
  }

  function isOpen(section, name) { return !!opened[section + "/" + name] }
  function open(section, name) { opened = Object.assign({}, opened, { [section + "/" + name]: true }) }
  function toggle(section, name) { opened = Object.assign({}, opened, { [section + "/" + name]: !isOpen(section, name) }) }

  // Shows the item picked on the overview where it is edited.
  function reveal(section, name) {
    wanted({ auth: 0, models: 1, agents: 2, workflows: 3 }[section])
    if (section === "agents")
      agent = name
    else
      open(section, name)
  }

  function remove(section, name) {
    removal = [section, name]
    confirmRemove.open()
  }

  function leave() {
    agent = ""
  }

  onActiveChanged: if (active) body.forceActiveFocus()

  // Esc that nothing inside took (an open list or dialog takes its own) goes back.
  ColumnLayout {
    id: body
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: view.leave()
    spacing: 18

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: view.document !== null

      Repeater {
        model: [secretsPage, modelsPage, agentsPage, workflowsPage, toolsPage, skillsPage, projectPage]
        delegate: Stage {
          id: stage
          required property var modelData
          required property int index
          anchors.fill: parent
          shown: view.page === index
          Loader { anchors.fill: parent; active: view.document !== null; sourceComponent: stage.modelData }
        }
      }
    }

    Label {
      visible: view.document === null
      text: Studio.connected ? "reading the config" : "the server does not answer"
      color: Theme.dim
    }
  }

  // An item's name; a new one is saved under it, an old one renamed.
  component NameField: Field {
    required property ItemCard card
    visible: !card.single
    Layout.fillWidth: true
    label: "name"
    value: card.newName
    error: card.nameIssue
    onEdited: text => card.newName = text.trim()
  }

  // An optional whole number of a card's draft: left empty, the key leaves it.
  component OptionalNumber: Field {
    id: optional
    required property ItemCard card
    required property var path
    readonly property var number: card ? optional.path.reduce((at, key) => at && at[key], card.draft) : undefined
    Layout.fillWidth: false
    value: number === undefined || number === null ? "" : String(number)
    placeholder: "unset"
    input.validator: RegularExpressionValidator { regularExpression: /[0-9]{0,9}/ }
    input.inputMethodHints: Qt.ImhDigitsOnly
    onEdited: text => card.put(optional.path, text === "" ? null : Number(text))
  }

  component Note: Label {
    Layout.fillWidth: true
    color: Theme.dim
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }

  Component {
    id: secretsPage
    ScrollPage {
      id: scroll
      contentHeight: content.implicitHeight
      ColumnLayout {
        id: content
        width: scroll.width
        spacing: 10
        Note { text: "Where each provider's key comes from. Models name their provider; the key itself is never shown here." }
        Repeater {
          model: view.listed.auth
          delegate: ItemCard {
            id: card
            required property string modelData
            readonly property bool literal: view.literalKeys.includes(modelData) && draft.key === undefined
            readonly property var omapass: Studio.omapass
            readonly property string key: draft.key === undefined ? "" : String(draft.key)
            readonly property var omapassKey: /^!(.*omapass'?) get -- (.+)$/.exec(key)
            readonly property string source: literal ? "file"
              : draft.key === undefined || key === "" ? "login"
              : key.startsWith("$") ? "variable"
              : omapassKey ? "omapass"
              : key.startsWith("!") ? "command"
              : "file"
            readonly property var users: view.keysOf("models").filter(name => view.document.models[name].provider === modelData)
            section: "auth"
            name: modelData
            stored: view.stored("auth", modelData)
            fresh: ({ kind: "api_key", key: "" })
            taken: view.listed.auth
            expanded: view.isOpen("auth", modelData)
            note: (draft.kind || "") + (draft.kind === "api_key" ? "  ·  " + ({ file: "in the file", login: "stored login", variable: key, omapass: "omapass", command: "command" })[source] : "")
              + (users.length ? "  ·  " + users.join(", ") : "")
            onToggled: view.toggle("auth", modelData)
            onRemoving: view.remove("auth", modelData)
            onDropped: view.drop("auth", modelData)

            function quoted(text) { return /^[A-Za-z0-9_.\/@:+=-]+$/.test(text) ? text : "'" + text.replace(/'/g, "'\\''") + "'" }
            function unquoted(text) { return /^'.*'$/.test(text) ? text.slice(1, -1).replace(/'\\''/g, "'") : text }
            function fromOmapass(account) { return "!" + quoted(omapass.program) + " get -- " + quoted(account) }

            NameField { card: card }
            PickRow {
              text: "KIND"
              options: ["api_key", "oauth-code", "tool"]
              current: card.draft.kind || ""
              onPicked: kind => card.put(["kind"], kind)
            }
            Caption { visible: card.draft.kind === "api_key"; text: "KEY FROM" }
            Flow {
              Layout.fillWidth: true
              visible: card.draft.kind === "api_key"
              spacing: 6
              Chip {
                text: "VARIABLE"
                checked: card.source === "variable"
                onClicked: card.put(["key"], "$" + card.modelData.toUpperCase().replace(/[^A-Z0-9]/g, "_") + "_API_KEY")
              }
              Chip {
                text: "COMMAND"
                checked: card.source === "command"
                onClicked: card.put(["key"], "!")
              }
              Chip {
                visible: card.source === "omapass" || (card.omapass !== null && card.omapass.installed)
                text: "OMAPASS"
                checked: card.source === "omapass"
                onClicked: if (card.omapass && card.omapass.installed) card.put(["key"], card.fromOmapass((card.omapass.accounts[0] || { account: "" }).account))
              }
              Chip {
                text: "STORED LOGIN"
                checked: card.source === "login"
                onClicked: card.put(["key"], "")
              }
              Chip {
                visible: view.literalKeys.includes(card.modelData)
                text: "IN THE FILE"
                checked: card.source === "file"
                onClicked: card.put(["key"], null)
              }
            }
            Field {
              visible: card.draft.kind === "api_key" && card.source === "variable"
              Layout.fillWidth: true
              label: "environment variable of the server"
              value: card.key.slice(1)
              onEdited: text => card.put(["key"], "$" + text.trim())
            }
            Field {
              visible: card.draft.kind === "api_key" && card.source === "command"
              Layout.fillWidth: true
              label: "command that prints the key"
              value: card.key.slice(1)
              onEdited: text => card.put(["key"], "!" + text)
            }
            PickRow {
              visible: card.draft.kind === "api_key" && card.source === "omapass" && card.omapass !== null && card.omapass.installed
              text: "PASSWORD"
              options: card.omapass && card.omapass.accounts ? card.omapass.accounts.map(item => item.account) : []
              current: card.omapassKey ? card.unquoted(card.omapassKey[2]) : ""
              describe: account => {
                const item = ((card.omapass || {}).accounts || []).find(entry => entry.account === account)
                return item && item.folder ? item.folder + " / " + account : account
              }
              onPicked: account => card.put(["key"], card.fromOmapass(account))
            }
            FieldError {
              Layout.fillWidth: true
              visible: card.draft.kind === "api_key" && card.source === "omapass"
              text: card.omapass === null ? "" : !card.omapass.installed ? "omapass is not installed; this key cannot be read" : card.omapass.error || ""
            }
            Note {
              visible: card.draft.kind === "api_key" && card.source === "login"
              text: "The key a login stored for " + card.modelData + "; `omunculus login --provider " + card.modelData + "` stores it."
            }
            Note {
              visible: card.draft.kind === "api_key" && card.source === "file"
              text: "The key is written in the project's config as it is; it stays there, unread here."
            }
            // The other kinds keep their own fields as text.
            Repeater {
              model: card.draft.kind === "api_key" ? [] : Object.keys(card.draft).filter(key => key !== "kind" && typeof card.draft[key] === "string")
              delegate: Field {
                required property string modelData
                Layout.fillWidth: true
                label: modelData.replace(/_/g, " ")
                value: card.draft[modelData]
                onEdited: text => card.put([modelData], text)
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: modelsPage
    ScrollPage {
      id: scroll
      contentHeight: content.implicitHeight
      ColumnLayout {
        id: content
        width: scroll.width
        spacing: 10
        Note { text: "What the agents run on: an api, the model's id and the options sent with every request. Test one before an agent runs on it." }
        Repeater {
          model: view.listed.models
          delegate: ItemCard {
            id: card
            required property string modelData
            readonly property bool http: ["openai-completions", "openai-responses", "anthropic-messages"].includes(draft.api)
            property bool testing: false
            property string tested: ""
            property bool testFailed: false
            section: "models"
            name: modelData
            stored: view.stored("models", modelData)
            fresh: ({ api: "openai-completions", model: "", url: "", timeout_ms: 120000 })
            taken: view.listed.models
            expanded: view.isOpen("models", modelData)
            note: (draft.api || "") + (draft.model ? "  ·  " + draft.model : draft.module ? "  ·  " + draft.module : "") + (draft.provider ? "  ·  " + draft.provider : "")
            onToggled: view.toggle("models", modelData)
            onRemoving: view.remove("models", modelData)
            onDropped: view.drop("models", modelData)
            onDraftChanged: tested = ""

            function test() {
              testing = true
              tested = ""
              Studio.testModel(newName, draft, result => {
                testing = false
                testFailed = false
                tested = "answered in " + (result.ms / 1000).toFixed(1) + " s: " + String(result.reply).replace(/\s+/g, " ").slice(0, 160)
              }, reason => {
                testing = false
                testFailed = true
                tested = reason
              })
            }

            NameField { card: card }
            RowLayout {
              Layout.fillWidth: true
              spacing: 16
              PickRow {
                text: "API"
                options: ["openai-completions", "openai-responses", "anthropic-messages", "command", "module"]
                current: card.draft.api || ""
                onPicked: api => card.put(["api"], api)
              }
              PickRow {
                visible: card.draft.api !== "module"
                text: "PROVIDER"
                options: [""].concat(view.listed.auth)
                current: card.draft.provider || ""
                describe: name => name === "" ? "none" : name
                invalid: !!card.draft.provider && !view.listed.auth.includes(card.draft.provider)
                onPicked: name => card.put(["provider"], name === "" ? null : name)
              }
              Item { Layout.fillWidth: true }
            }
            Field {
              Layout.fillWidth: true
              visible: card.draft.api !== "module"
              label: "model id"
              value: card.draft.model || ""
              onEdited: text => card.put(["model"], text === "" ? null : text)
            }
            Field {
              Layout.fillWidth: true
              visible: card.http
              label: "url"
              value: card.draft.url || ""
              onEdited: text => card.put(["url"], text === "" ? null : text)
            }
            RowLayout {
              Layout.fillWidth: true
              visible: card.http
              spacing: 16
              OptionalNumber { card: card; path: ["timeout_ms"]; Layout.preferredWidth: 160; label: "timeout ms" }
              Chip {
                Layout.alignment: Qt.AlignBottom
                text: "STREAM"
                tip: "read the reply as it is written"
                checked: !!card.draft.stream
                onClicked: card.put(["stream"], card.draft.stream ? null : true)
              }
              Item { Layout.fillWidth: true }
            }
            BodyFields {
              Layout.fillWidth: true
              visible: card.http
              api: card.draft.api || ""
              table: card.draft.body || {}
              onChanged: table => card.put(["body"], Object.keys(table).length ? table : null)
            }
            Field {
              Layout.fillWidth: true
              visible: card.draft.api === "module"
              label: "module"
              value: card.draft.module || ""
              onEdited: text => card.put(["module"], text === "" ? null : text)
            }
            SettingsTextArea {
              Layout.fillWidth: true
              visible: card.draft.api === "command"
              label: "command, one argument per line"
              lines: 4
              value: (card.draft.command || []).join("\n")
              onEdited: text => card.put(["command"], text.split("\n").filter(line => line !== ""))
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: 10
              TraceButton {
                visible: card.draft.api !== "command"
                dense: true
                role: "progress"
                icon: "play"
                text: card.testing ? "TESTING" : "TEST"
                tip: "send it one short prompt, as it is here"
                busy: card.testing
                enabled: !card.testing && card.nameIssue === ""
                onClicked: card.test()
              }
              Label {
                Layout.fillWidth: true
                text: card.draft.api === "command" ? "A command model runs in the sandbox an agent's ceiling makes; a run tests it." : card.tested
                color: card.testFailed && card.draft.api !== "command" ? Theme.error : Theme.dim
                font.pixelSize: 11
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: agentsPage
    Item {
      // The agents.
      Stage {
        anchors.fill: parent
        shown: view.agent === ""
        ScrollPage {
          id: scroll
          anchors.fill: parent
          contentHeight: content.implicitHeight
          ColumnLayout {
            id: content
            width: scroll.width
            spacing: 8
            Note { text: "Who works: each agent at its depth, on a model, with its text and what it may do. Depth 0 talks with you. Pick one to shape it." }
            Repeater {
              model: view.listed.agents
              delegate: Rectangle {
                id: entry
                required property string modelData
                readonly property var agent: view.stored("agents", modelData) || {}
                Layout.fillWidth: true
                implicitHeight: 48
                color: pointer.containsMouse ? Theme.highlight : Theme.background
                border.color: pointer.containsMouse ? Theme.primary : Theme.line
                Behavior on color { ColorAnimation { duration: 140 } }
                RowLayout {
                  anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                  spacing: 14
                  Label { text: entry.modelData; color: Studio.toneOf(entry.modelData); font.pixelSize: 12; font.letterSpacing: 1 }
                  Label {
                    Layout.fillWidth: true
                    text: view.stored("agents", entry.modelData) === null ? "new" :
                      "depth " + entry.agent.depth + "  ·  " + (entry.agent.model || "no model") + "  ·  " + ((entry.agent.tools || entry.agent.granted || []).length) + " tools"
                      + (entry.agent.workflow_only ? "  ·  workflow only" : "")
                    color: Theme.dim
                    font.pixelSize: 10
                    elide: Text.ElideRight
                  }
                  Icon { name: "chevron-right"; size: 12; color: Theme.dim }
                }
                MouseArea {
                  id: pointer
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: view.agent = entry.modelData
                }
              }
            }
          }
        }
      }

      // One agent, on its own screen.
      Stage {
        anchors.fill: parent
        shown: view.agent !== ""
        ScrollPage {
          id: one
          anchors.fill: parent
          contentHeight: screen.implicitHeight
          ColumnLayout {
            id: screen
            width: one.width
            spacing: 12
            Chip { text: "AGENTS"; icon: "chevron-left"; tip: "back to the agents (Esc)"; onClicked: view.agent = "" }
            Repeater {
              model: view.agent === "" ? [] : [view.agent]
              delegate: ItemCard {
                id: card
                required property string modelData
                section: "agents"
                name: modelData
                stored: view.stored("agents", modelData)
                fresh: ({ depth: 1, model: view.listed.models[0] || "", text: "" })
                taken: view.listed.agents
                expanded: true
                note: "depth " + draft.depth + "  ·  " + (draft.model || "no model")
                onToggled: view.agent = ""
                onRemoving: view.remove("agents", modelData)
                onDropped: { view.drop("agents", modelData); view.agent = "" }
                // A rename saved puts the agent's screen on its new name.
                onStoredChanged: if (stored === null && view.listed.agents.includes(newName) && newName !== name) view.agent = newName

                NameField { card: card }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 16
                  NumberField {
                    Layout.fillWidth: false
                    Layout.preferredWidth: 120
                    label: "depth"
                    number: card.draft.depth || 0
                    minimum: 0
                    onNumberEdited: number => card.put(["depth"], number)
                  }
                  PickRow {
                    text: "MODEL"
                    options: view.listed.models
                    current: card.draft.model || ""
                    invalid: !view.listed.models.includes(card.draft.model)
                    onPicked: model => card.put(["model"], model)
                  }
                  Chip {
                    Layout.alignment: Qt.AlignBottom
                    text: "WORKFLOW ONLY"
                    tip: "runs only as a stage of a workflow"
                    checked: !!card.draft.workflow_only
                    onClicked: card.put(["workflow_only"], card.draft.workflow_only ? null : true)
                  }
                  Item { Layout.fillWidth: true }
                }
                SettingsTextArea {
                  Layout.fillWidth: true
                  label: "text"
                  lines: 16
                  value: card.draft.text || ""
                  onEdited: text => card.put(["text"], text)
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
                      checked: (card.draft[Studio.hasKey(card.draft)] || []).includes("skills")
                      onClicked: card.replace(Studio.withAllSkills(card.draft, !checked))
                    }
                    Repeater {
                      model: Studio.skillNames
                      delegate: Chip {
                        required property string modelData
                        text: modelData
                        checked: Studio.hasSkill(card.draft, modelData)
                        onClicked: card.replace(Studio.withSkill(card.draft, modelData, !checked))
                      }
                    }
                  }
                  Note {
                    visible: Studio.skillNames.length === 0
                    text: "No skill in [skills] paths."
                  }
                }
                CeilingFields {
                  Layout.fillWidth: true
                  table: card.draft
                  choices: view.names
                  onChanged: table => card.replace(table)
                }
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: workflowsPage
    ScrollPage {
      id: scroll
      contentHeight: content.implicitHeight
      ColumnLayout {
        id: content
        width: scroll.width
        spacing: 10
        Note { text: "The stages a work goes through, in order, each run by its agent; what a stage never has is taken from its agent there." }
        Repeater {
          model: view.listed.workflows
          delegate: ItemCard {
            id: card
            required property string modelData
            readonly property var steps: draft.steps || []
            section: "workflows"
            name: modelData
            stored: view.stored("workflows", modelData)
            fresh: ({ steps: [{ name: "to_do", agent: view.listed.agents[0] || "" }] })
            taken: view.listed.workflows
            expanded: view.isOpen("workflows", modelData)
            note: steps.map(step => step.name).join("  →  ")
            onToggled: view.toggle("workflows", modelData)
            onRemoving: view.remove("workflows", modelData)
            onDropped: view.drop("workflows", modelData)

            function changed(index, key, value) {
              const next = JSON.parse(JSON.stringify(steps))
              if (value === null || (Array.isArray(value) && value.length === 0))
                delete next[index][key]
              else
                next[index][key] = value
              card.put(["steps"], next)
            }

            NameField { card: card }
            Repeater {
              model: card.steps.length
              delegate: SurfaceFrame {
                id: stage
                required property int index
                readonly property var step: card.steps[index] || {}
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
                      onEdited: text => card.changed(stage.index, "name", text)
                    }
                    PickRow {
                      text: "AGENT"
                      options: view.listed.agents
                      current: stage.step.agent || ""
                      invalid: !view.listed.agents.includes(stage.step.agent)
                      onPicked: agent => card.changed(stage.index, "agent", agent)
                    }
                    IconButton {
                      enabled: stage.index > 0
                      opacity: enabled ? 1 : 0.3
                      name: "chevron-up"
                      tip: "move up"
                      onClicked: {
                        const next = JSON.parse(JSON.stringify(card.steps))
                        next.splice(stage.index - 1, 0, next.splice(stage.index, 1)[0])
                        card.put(["steps"], next)
                      }
                    }
                    IconButton {
                      name: "close"
                      tone: Theme.error
                      tip: "remove the stage"
                      onClicked: card.put(["steps"], card.steps.filter((_, at) => at !== stage.index))
                    }
                  }
                  NameSet {
                    Layout.fillWidth: true
                    label: "never has in this stage"
                    items: stage.step.deny || []
                    choices: view.names
                    onChanged: items => card.changed(stage.index, "deny", items)
                  }
                }
              }
            }
            Chip {
              text: "ADD STAGE"
              icon: "plus"
              onClicked: card.put(["steps"], card.steps.concat([{ name: "stage_" + (card.steps.length + 1), agent: view.listed.agents[0] || "" }]))
            }
          }
        }
      }
    }
  }

  Component {
    id: toolsPage
    ToolsView {}
  }

  Component {
    id: skillsPage
    SkillsView {}
  }

  Component {
    id: projectPage
    ScrollPage {
      id: scroll
      contentHeight: content.implicitHeight
      ColumnLayout {
        id: content
        width: scroll.width
        spacing: 10

        Kicker { Layout.fillWidth: true; text: "POLICY" }
        ItemCard {
          id: policy
          section: "policy"
          single: true
          stored: view.document.policy || null
          expanded: view.isOpen("policy", "")
          note: "max retries " + (draft.max_retries === undefined ? "unset" : draft.max_retries)
          onToggled: view.toggle("policy", "")

          Field {
            Layout.fillWidth: true
            label: "assemble"
            value: policy.draft.assemble || ""
            onEdited: text => policy.put(["assemble"], text === "" ? null : text)
          }
          Note { text: "The tool that writes each run's prompt." }
          RowLayout {
            Layout.fillWidth: true
            spacing: 16
            OptionalNumber { card: policy; path: ["max_retries"]; Layout.preferredWidth: 140; label: "max retries" }
            OptionalNumber { card: policy; path: ["last_run_output_bytes"]; Layout.preferredWidth: 180; label: "last run output bytes" }
            OptionalNumber { card: policy; path: ["tool_output_bytes"]; Layout.preferredWidth: 180; label: "tool output bytes" }
            Item { Layout.fillWidth: true }
          }
          Note { text: "How often a work whose model stopped without a report runs again, and how much of each output a prompt keeps." }
          RowLayout {
            Layout.fillWidth: true
            spacing: 16
            PickRow {
              text: "DEFAULT WORKSPACE"
              options: [""].concat(view.keysOf("workspaces"))
              current: policy.draft.workspace || ""
              describe: name => name === "" ? "the project root" : name
              onPicked: name => policy.put(["workspace"], name === "" ? null : name)
            }
            PickRow {
              text: "DEFAULT WORKFLOW"
              options: [""].concat(view.keysOf("workflows"))
              current: policy.draft.workflow || ""
              describe: name => name === "" ? "none" : name
              onPicked: name => policy.put(["workflow"], name === "" ? null : name)
            }
            Item { Layout.fillWidth: true }
          }
          Caption { text: "CEILING OF EVERY RUN" }
          CeilingFields {
            Layout.fillWidth: true
            table: policy.draft
            choices: view.names
            onChanged: table => policy.replace(table)
          }
        }

        Kicker { Layout.fillWidth: true; Layout.topMargin: 8; text: "WORKSPACES" }
        Note { text: "Where the agents work: a directory, relative to the project root, with the ceiling that holds there. Without one, they work in the project root." }
        Repeater {
          model: view.listed.workspaces
          delegate: ItemCard {
            id: card
            required property string modelData
            section: "workspaces"
            name: modelData
            stored: view.stored("workspaces", modelData)
            fresh: ({ root: "." })
            taken: view.listed.workspaces
            expanded: view.isOpen("workspaces", modelData)
            note: draft.root || ""
            onToggled: view.toggle("workspaces", modelData)
            onRemoving: view.remove("workspaces", modelData)
            onDropped: view.drop("workspaces", modelData)

            NameField { card: card }
            Field {
              Layout.fillWidth: true
              label: "root"
              value: card.draft.root || ""
              onEdited: text => card.put(["root"], text)
            }
            CeilingFields {
              Layout.fillWidth: true
              table: card.draft
              choices: view.names
              onChanged: table => card.replace(table)
            }
          }
        }

        Kicker { Layout.fillWidth: true; Layout.topMargin: 8; text: "ACCESS" }
        Note {
          text: view.document.access ? "Who may do what, by role; the members of each role are in the store, not here."
            : "This project has no [access]: only its local user works in it."
        }
        ItemCard {
          id: access
          visible: view.document.access !== undefined
          section: "access"
          single: true
          stored: view.document.access || null
          expanded: view.isOpen("access", "")
          readonly property var roles: draft.roles || {}
          note: Object.keys(roles).join(", ")
          onToggled: view.toggle("access", "")

          function renamed(from, to) {
            const next = {}
            for (const key of Object.keys(roles))
              next[key === from ? to : key] = roles[key]
            access.put(["roles"], next)
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: 16
            PickRow {
              text: "A CONVERSATION'S CREATOR"
              options: Object.keys(access.roles)
              current: access.draft.creator_role || ""
              onPicked: role => access.put(["creator_role"], role)
            }
            PickRow {
              text: "THE FIRST ADMINISTRATOR"
              options: Object.keys(access.roles)
              current: access.draft.bootstrap_role || ""
              onPicked: role => access.put(["bootstrap_role"], role)
            }
            Item { Layout.fillWidth: true }
          }
          Repeater {
            model: Object.keys(access.roles).length
            delegate: SurfaceFrame {
              id: role
              required property int index
              readonly property string roleName: Object.keys(access.roles)[index] || ""
              readonly property var entry: access.roles[roleName] || {}
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
                      if (/^[A-Za-z0-9_-]+$/.test(name) && access.roles[name] === undefined)
                        access.renamed(role.roleName, name)
                    }
                  }
                  PickRow {
                    text: "SCOPE"
                    options: ["project", "conversation"]
                    current: role.entry.scope || ""
                    onPicked: scope => access.put(["roles", role.roleName, "scope"], scope)
                  }
                  IconButton {
                    name: "close"
                    tone: Theme.error
                    tip: "remove the role"
                    onClicked: access.put(["roles", role.roleName], null)
                  }
                }
                NameSet {
                  Layout.fillWidth: true
                  label: "capabilities"
                  items: role.entry.capabilities || []
                  choices: view.capabilities
                  closed: true
                  onChanged: items => access.put(["roles", role.roleName, "capabilities"], items)
                }
              }
            }
          }
          Chip {
            text: "ADD ROLE"
            icon: "plus"
            onClicked: {
              let name = "role"
              for (let n = 2; access.roles[name] !== undefined; n++)
                name = "role_" + n
              access.put(["roles", name], { scope: "conversation", capabilities: ["conversation.read"] })
            }
          }
        }
      }
    }
  }

  ConfirmDialog {
    id: confirmRemove
    title: "remove " + (view.removal ? view.removal[1] : "")
    question: view.removal ? "Remove " + view.removal[1] + " from the project's config? It is refused while something still uses it." : ""
    confirmText: "REMOVE"
    onConfirmed: {
      const [section, name] = view.removal
      Studio.configure(section + "." + name, null, "", () => {
        if (section === "agents")
          view.agent = ""
      }, reason => Studio.tell(reason, true))
    }
  }
}
