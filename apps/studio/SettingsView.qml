pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// SettingsView shapes the project's config in the order its parts depend on
// each other: the secrets of the providers, the models that use them, the
// agents on those models, the workflows of those agents, the tools and the
// skills of the catalog, and the project's own policy, workspaces and
// access, and the usage of its model replies, one section at a time. Each
// section is a table of its items; a
// click picks one, a double click or Enter opens it on a screen of its kind,
// read, where it may be edited and saved on its own through the config
// routes, which write it only if the result loads. What is picked or open
// decides the commands the bar shows.
Item {
  id: view

  property bool active: false
  // The sections' names, in order, each heading its table.
  property var headings: []
  // The section on screen: secrets, models, agents, workflows, tools,
  // skills or the project, 0 to 6.
  property int page: 0
  // A section asked for, as when an item of another is revealed.
  signal wanted(int page)

  // Section -> names added here and not saved yet.
  property var pending: ({})
  // The names of each section, replaced only when they change.
  property var listed: ({ auth: [], models: [], agents: [], workflows: [], workspaces: [] })
  // Section index -> the id of the row picked, and of the item open, or "".
  property var picked: ({})
  property var shown: ({})
  // An item opened to be written, as one just added.
  property var editing: ({})
  // What a removal asks to remove: [section, name].
  property var removal: null

  readonly property var document: Studio.setup ? Studio.setup.document : null
  readonly property var names: Studio.setup ? Studio.setup.names : []
  readonly property var literalKeys: Studio.setup ? Studio.setup.literal_keys : []
  readonly property var catalog: Studio.catalog
  // Every agent, the packs' included, then those added and not saved.
  readonly property var allAgents: (Studio.setup ? Studio.setup.agents.map(agent => agent.name) : [])
    .concat(listed.agents.filter(name => !(Studio.setup ? Studio.setup.agents : []).some(agent => agent.name === name)))
  readonly property var allWorkflows: (Studio.setup ? Studio.setup.workflows.map(flow => flow.name) : [])
    .concat(listed.workflows.filter(name => !(Studio.setup ? Studio.setup.workflows : []).some(flow => flow.name === name)))

  // The page of the item open on the section on screen, or null.
  property Item openPage: null
  readonly property var commands: openPage ? openPage.commands : sections[page].commands()

  function stored(section, name) {
    return document && document[section] && document[section][name] !== undefined ? document[section][name] : null
  }
  function keysOf(section) { return document && document[section] ? Object.keys(document[section]) : [] }
  // The pack an agent or workflow the config does not write comes from.
  function originOf(section, name) {
    if (stored(section, name) !== null)
      return ""
    const pack = (Studio.setup ? Studio.setup.packs : []).find(entry => (entry[section] || []).includes(name))
    return pack ? pack.name : ""
  }

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

  function setOf(map, index, value) { return Object.assign({}, map, { [index]: value }) }

  // Opens the item `id` of the section `index`, written when `write`.
  function open(index, id, write) {
    picked = setOf(picked, index, id)
    editing = setOf(editing, index, !!write)
    // Already open, it only starts or stops being written.
    if (shown[index] === id && index === page && openPage) {
      openPage.editing = !!write
      return
    }
    shown = setOf(shown, index, id)
  }
  function close(index) {
    const id = shown[index] || ""
    const section = sections[index].key
    if (section && (pending[section] || []).includes(id))
      drop(section, id)
    shown = setOf(shown, index, "")
    // Back from a followed item: to the screen it was followed from.
    if (history.length > 0) {
      const from = history[history.length - 1]
      history = history.slice(0, -1)
      wanted(from.section)
      if (from.id !== "")
        open(from.section, from.id, false)
      // The screen come back to still holds the keyboard's place.
      Qt.callLater(takeFocus)
      return
    }
    // Back on the table, the keyboard is on its rows again.
    Qt.callLater(() => tables[index] && tables[index].focusRows())
  }
  // Section index -> its table, for the keyboard.
  property var tables: ({})

  // Adds a new item of `section`, not saved yet, and opens it to be written.
  function create(section) {
    const index = sections.findIndex(entry => entry.key === section)
    const stem = sections[index].stem
    let name = stem
    for (let n = 2; listed[section].includes(name); n++)
      name = stem + "_" + n
    pending = Object.assign({}, pending, { [section]: (pending[section] || []).concat([name]) })
    relist()
    open(index, sections[index].idOf(name), true)
  }
  function drop(section, name) {
    pending = Object.assign({}, pending, { [section]: (pending[section] || []).filter(item => item !== name) })
    relist()
  }

  // A link to the item `id` of the section `index`, as related items are.
  function link(index, id, text) { return { section: index, id: id, text: text || id } }
  // The catalog's tools (not skills) an agent's list holds, by name or by group.
  function toolsHeld(held) {
    return (catalog ? catalog.tools : []).filter(entry => entry.kind !== "skill"
      && (held.includes(entry.name) || entry.groups.some(group => held.includes(group))))
  }
  // The skills an agent's list holds: all of them by the skills group, or each by name.
  function skillsHeld(held) {
    return (catalog ? catalog.tools : []).filter(entry => entry.kind === "skill" && (held.includes("skills") || held.includes(entry.name)))
  }
  // Opens a related item, in its own section.
  // Following one, the screen it was followed from is remembered, so going
  // back from it comes back there.
  function follow(index, id) {
    history = history.concat([{ section: page, id: shown[page] || "" }])
    wanted(index)
    open(index, id, false)
  }
  // The screens related items were followed from, the last last.
  property var history: []
  // Choosing a section elsewhere starts the way back over.
  function forget() { history = [] }

  // Shows an item picked elsewhere, as on the flow, where it is read.
  function reveal(section, name) {
    const index = sections.findIndex(entry => entry.key === section)
    wanted(index)
    open(index, sections[index].idOf(name), false)
  }

  function remove(section, name) {
    removal = [section, name]
    confirmRemove.open()
  }

  // Gives the keyboard to the section on screen: its open item, or its rows.
  function takeFocus() {
    if (openPage)
      openPage.takeFocus()
    else if (tables[page])
      tables[page].focusRows()
  }

  function leave() {
    if (openPage)
      openPage.leave()
  }

  // Each section: its key in the config (or "" for what it does not write),
  // the stem of a new item's name, its table and the screen of an item.
  readonly property var sections: [
    {
      key: "auth", stem: "provider", add: "ADD PROVIDER",
      note: "Where each provider's key comes from. Models name their provider; the key itself is never shown here.",
      stacked: [[0], [1, 2], [3]],
      columns: [{ title: "provider", weight: 0.25 }, { title: "kind", weight: 0.15 }, { title: "key from", weight: 0.35 }, { title: "models", weight: 0.25 }],
      rows: () => listed.auth.map(name => {
        const table = stored("auth", name) || {}
        const key = table.key === undefined ? "" : String(table.key)
        return { id: name, name: name, editable: true, cells: [name, table.kind || "new",
          table.kind !== "api_key" ? "" : literalKeys.includes(name) && table.key === undefined ? "the file" : key === "" ? "a stored login" : key.startsWith("$") ? key : key.startsWith("!") ? "a command" : "the file",
          keysOf("models").filter(model => document.models[model].provider === name).join(", ")] }
      }),
      idOf: name => name, file: "ProviderView.qml", props: row => ({ name: row.name })
    },
    {
      key: "models", stem: "model", add: "ADD MODEL",
      note: "What the agents run on: an api, the model's id and the options sent with every request. Test one before an agent runs on it.",
      stacked: [[0], [1, 3], [2]],
      columns: [{ title: "model", weight: 0.2 }, { title: "api", weight: 0.2 }, { title: "model id", weight: 0.4 }, { title: "provider", weight: 0.2 }],
      rows: () => listed.models.map(name => {
        const table = stored("models", name) || {}
        return { id: name, name: name, editable: true, cells: [name, table.api || "new", table.model || table.module || "", table.provider || ""] }
      }),
      idOf: name => name, file: "ModelView.qml", props: row => ({ name: row.name })
    },
    {
      key: "agents", stem: "agent", add: "ADD AGENT",
      note: "Who works: each agent at its depth, on a model, with its text and what it may do. Depth 0 talks with you.",
      stacked: [[0], [1, 2, 3], [4]],
      columns: [{ title: "agent", weight: 0.24 }, { title: "depth", weight: 0.1 }, { title: "model", weight: 0.18 }, { title: "has", weight: 0.14 }, { title: "from", weight: 0.34 }],
      rows: () => allAgents.map(name => {
        const agent = (Studio.setup ? Studio.setup.agents : []).find(entry => entry.name === name) || stored("agents", name) || {}
        const origin = originOf("agents", name)
        return { id: name, name: name, editable: origin === "", cells: [name, agent.depth === undefined ? "" : String(agent.depth), agent.model || "",
          (agent.granted || agent.tools || []).length + " tools" + (agent.workflow_only ? " · workflow only" : ""), origin ? "◆ " + origin : "the project"] }
      }),
      idOf: name => name, file: "AgentView.qml", props: row => ({ name: row.name })
    },
    {
      key: "workflows", stem: "workflow", add: "ADD WORKFLOW",
      note: "The stages a work goes through, in order, each run by its agent; what a stage never has is taken from its agent there.",
      stacked: [[0], [1], [2]],
      columns: [{ title: "workflow", weight: 0.16 }, { title: "stages", weight: 0.6 }, { title: "from", weight: 0.24 }],
      rows: () => allWorkflows.map(name => {
        const flow = stored("workflows", name) || (Studio.setup ? Studio.setup.workflows : []).find(entry => entry.name === name) || {}
        const origin = originOf("workflows", name)
        return { id: name, name: name, editable: origin === "", cells: [name, (flow.steps || []).map(step => step.name + " (" + step.agent + ")").join("  →  "),
          origin ? "◆ " + origin : "the project"] }
      }),
      idOf: name => name, file: "WorkflowView.qml", props: row => ({ name: row.name })
    },
    {
      key: "", stem: "", add: "",
      note: "The catalog: the tools of [tools] paths and the package, and the MCP servers the config starts. Read here; a tool is a folder.",
      stacked: [[0], [1, 2, 3], [4]],
      columns: [{ title: "tool", weight: 0.24 }, { title: "kind", weight: 0.12 }, { title: "groups", weight: 0.2 }, { title: "triggers", weight: 0.16 }, { title: "had by", weight: 0.28 }],
      rows: () => (catalog ? catalog.tools.filter(entry => entry.kind !== "skill").concat(catalog.mcp.map(server => ({
          name: server.name, kind: "mcp server", description: server.command.join(" "), triggers: [], groups: [],
          secrets: Object.keys(server.secrets), binding: server.secrets, source: "mcp", dir: "" }))) : [])
        .map(entry => ({ id: entry.name, entry: entry, editable: false, cells: [entry.name, entry.kind, entry.groups.join(", "), entry.triggers.join(", "),
          entry.triggers.includes("model") ? Studio.holders(entry.name).join(", ") : ""] })),
      idOf: name => name, file: "ToolView.qml", props: row => ({ entry: row.entry })
    },
    {
      key: "", stem: "", add: "",
      note: "Read from [skills] paths. An agent has them through the skills group, or one as skill.<name>, and reads one with the skill tool.",
      stacked: [[0], [1], [2]],
      columns: [{ title: "skill", weight: 0.2 }, { title: "what it is for", weight: 0.55 }, { title: "had by", weight: 0.25 }],
      rows: () => (catalog ? catalog.tools.filter(entry => entry.kind === "skill") : [])
        .map(entry => ({ id: entry.name, entry: entry, editable: false, cells: [entry.name.slice(6), entry.description, Studio.holders(entry.name).join(", ")] })),
      idOf: name => name, file: "SkillView.qml", props: row => ({ entry: row.entry })
    },
    {
      key: "workspaces", stem: "workspace", add: "ADD WORKSPACE",
      note: "The project's own: its policy, its workspaces — where the agents work, with the ceiling that holds there — and who may do what.",
      stacked: [[0], [1, 2]],
      columns: [{ title: "item", weight: 0.25 }, { title: "kind", weight: 0.15 }, { title: "what it holds", weight: 0.6 }],
      rows: () => {
        if (!document)
          return []
        const policy = document.policy || {}
        const rows = [{ id: "policy", name: "policy", editable: true, file: "PolicyView.qml", cells: ["policy", "policy",
          "max retries " + (policy.max_retries === undefined ? "unset" : policy.max_retries) + (policy.workspace ? "  ·  workspace " + policy.workspace : "")] }]
        if (document.access)
          rows.push({ id: "access", name: "access", editable: true, file: "AccessView.qml", cells: ["access", "access", Object.keys(document.access.roles || {}).join(", ")] })
        if (Studio.usage)
          rows.push({ id: "usage", name: "usage", editable: false, file: "UsageView.qml", cells: ["usage", "usage",
            Studio.usage.total.replies + " model replies"] })
        return rows.concat(listed.workspaces.map(name => ({ id: "workspace:" + name, name: name, editable: true, removable: true, file: "WorkspaceView.qml",
          cells: [name, "workspace", (stored("workspaces", name) || {}).root || "new"] })))
      },
      idOf: name => "workspace:" + name, file: "", props: row => row.file === "WorkspaceView.qml" ? ({ name: row.name }) : ({})
    }
  ].map((section, index) => Object.assign(section, {
    // The commands of the table: add, and, with a row picked, view and remove it.
    commands: () => {
      const row = section.rows().find(entry => entry.id === (picked[index] || "")) || null
      return [
        { text: section.add, short: section.add.replace("ADD ", ""), icon: "plus", role: "primary", shown: section.add !== "", run: () => view.create(section.key) },
        { text: "VIEW", icon: "enter", tip: "open it  enter", shown: row !== null, run: () => view.open(index, row.id, false) },
        { text: "DELETE", icon: "trash", role: "guarded", tip: "remove it from the project's config", shown: row !== null && row.editable && (section.key !== "workspaces" || !!row.removable),
          run: () => view.remove(section.key, row.name) }
      ]
    }
  }))

  // Esc that nothing inside took (an open list or dialog takes its own) goes back.
  Item {
    id: body
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: view.leave()

    Repeater {
      model: view.sections.length
      delegate: Stage {
        id: stage
        required property int index
        readonly property var section: view.sections[index]
        readonly property string open: view.shown[index] || ""
        anchors.fill: parent
        shown: view.page === index
        revealAll: true

        // The table of the section's items.
        ColumnLayout {
          anchors.fill: parent
          visible: stage.open === ""
          spacing: 12
          DecodeLabel {
            value: (view.headings[stage.index] || "").toUpperCase()
            color: Theme.primary
            font.pixelSize: 16
            font.letterSpacing: 4
          }
          Note { value: stage.section.note }
          DataTable {
            id: table
            Layout.fillWidth: true
            Layout.fillHeight: true
            Component.onCompleted: view.tables[stage.index] = table
            picks: true
            active: stage.shown && stage.open === ""
            columns: stage.section.columns
            stacked: stage.section.stacked
            rows: view.document === null ? [] : stage.section.rows()
            cells: row => row.cells
            tone: (row, column) => column === 0 && view.sections[stage.index].key === "agents" ? Studio.toneOf(row.name) : ""
            idOf: row => row.id
            selectedId: view.picked[stage.index] || ""
            loading: view.document === null && Studio.connected
            emptyText: view.document === null ? (Studio.connected ? "reading the config" : "the server does not answer") : "Nothing here yet."
            onPicked: row => view.picked = view.setOf(view.picked, stage.index, row.id)
            onOpened: row => view.open(stage.index, row.id, false)
            onRemoveRequested: row => { if (row.editable) view.remove(stage.section.key, row.name) }
          }
        }

        // The item open, on the screen of its kind.
        Loader {
          id: screen
          anchors.fill: parent
          active: stage.open !== ""
          readonly property var row: stage.open === "" || view.document === null ? null : stage.section.rows().find(entry => entry.id === stage.open) || null
          onRowChanged: load()
          onActiveChanged: load()
          function load() {
            if (!active || !row) {
              source = ""
              return
            }
            if (item && item.loadedId === row.id)
              return
            setSource(row.file || stage.section.file, Object.assign({ settings: view }, stage.section.props(row)))
          }
          onLoaded: {
            item.loadedId = row.id
            item.editing = !!view.editing[stage.index]
            // The keyboard goes with the screen that opens.
            Qt.callLater(() => { if (screen.item) screen.item.takeFocus() })
            item.back.connect(() => view.close(stage.index))
            item.followed.connect((section, id) => view.follow(section, id))
            item.removing.connect(() => view.remove(stage.section.key, row.name))
            // Saved under a new name, the screen follows it.
            if (item.draft && !item.draft.single)
              item.draft.saved.connect(name => view.shown = view.setOf(view.shown, stage.index, stage.section.idOf(name)))
          }
        }
        Binding {
          when: stage.shown
          target: view
          property: "openPage"
          value: screen.item
          restoreMode: Binding.RestoreNone
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
      const index = view.sections.findIndex(entry => entry.key === section)
      Studio.configure(section + "." + name, null, "", () => {
        view.shown = view.setOf(view.shown, index, "")
        view.picked = view.setOf(view.picked, index, "")
      }, reason => Studio.tell(reason, true))
    }
  }
}
