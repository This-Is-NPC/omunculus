pragma Singleton
import QtQuick
import Quickshell
import "kit/client"
import "kit/ui"

// Studio is the project as its settings see it: whether the server answers,
// its setup, catalog and passwords, and every project of the registry as its
// overview tool prints it. Every read and write goes to the server's local
// socket through curl, the writes through the configure tool.
Singleton {
  id: root

  readonly property string socket: Quickshell.env("OMUNCULUS_SOCKET")
  readonly property string project: Quickshell.env("OMUNCULUS_PROJECT")

  property bool connected: false
  // The project's setup, as the config tool prints it: {root, agents, models,
  // workspaces, workspace, workflows, document, literal_keys, revision, names};
  // null until it answers.
  property var setup: null

  property string message: ""
  property bool messageIsError: false
  property int noticeCount: 0

  Component.onCompleted: {
    if (socket === "" || project === "")
      tell("OMUNCULUS_SOCKET and OMUNCULUS_PROJECT are not set; start through apps/kit/run studio", true)
    else
      check()
  }

  // Whether the server answers, asked again every few seconds; once it does,
  // everything the settings show is read.
  function check() {
    call("GET", "/v1/identity", null, false, () => {
      if (!connected) {
        connected = true
        loadSetup()
        loadOmapass()
        loadOverviews()
        loadCatalog()
      }
    }, () => connected = false)
  }
  Timer { interval: 5000; repeat: true; running: root.socket !== ""; onTriggered: root.check() }

  function tell(text, isError) {
    message = text
    messageIsError = isError
    noticeCount++
  }

  function loadSetup() {
    call("POST", "/v1/cli", { argv: ["config"] }, false, data => setup = JSON.parse(data.output))
  }

  // An agent's colour, by its place among the setup's agents.
  function toneOf(name) {
    const at = setup ? setup.agents.findIndex(agent => agent.name === name) : -1
    return at < 0 ? Theme.dim : Theme.agentPalette[at % Theme.agentPalette.length]
  }

  // Every project of the server's registry, the one on screen among them, as
  // {id, socket}, as GET /v1/projects lists them on this socket.
  property var projects: []

  // Writes one item of the config through the configure tool ("agents.worker",
  // "policy"), or removes it for a null value, renaming `from` when given; then
  // reads the setup again. `failed` gets the server's reason.
  function configure(item, value, from, done, failed) {
    const argv = ["configure", "--item", item, "--value", JSON.stringify(value), "--revision", setup.revision]
    if (from)
      argv.push("--from", from)
    call("POST", "/v1/cli", { argv: argv }, false, () => {
      loadSetup()
      loadOverviews()
      done()
    }, reason => {
      loadSetup()
      failed(reason)
    })
  }

  // Sends one short prompt to the model `name` as `value` would make it, and
  // hands its {reply, ms}, or the reason it failed.
  function testModel(name, value, done, failed) {
    call("POST", "/v1/cli", { argv: ["model_test", "--name", name, "--value", JSON.stringify(value)] }, false,
      data => done(JSON.parse(data.output)), failed)
  }

  // Whether omapass is installed, its program and its passwords, as the omapass
  // tool prints them; null until it answers.
  property var omapass: null
  function loadOmapass() {
    call("POST", "/v1/cli", { argv: ["omapass"] }, false, data => omapass = JSON.parse(data.output))
  }

  // The skills of the project on screen, by name, from its catalog.
  readonly property var skillNames: catalog ? catalog.tools.filter(entry => entry.kind === "skill").map(entry => entry.name.slice(6)) : []

  // The list of an agent's table that holds what it has: `granted`, or `tools`
  // as the presets write it.
  function hasKey(table) { return table.granted !== undefined ? "granted" : "tools" }

  // Whether the agent table `table` has the skill `name`: by the skills group, or by its own entry.
  function hasSkill(table, name) {
    const list = table[hasKey(table)] || []
    return list.includes("skills") || list.includes("skill." + name)
  }

  // `table` with the skill `name` given (`on`) or taken. A skill named on its
  // own comes with the skill tool, which reads it; taking one of the skills
  // group lists the others instead of the group.
  function withSkill(table, name, on) {
    const key = hasKey(table)
    let list = (table[key] || []).slice()
    if (on && !hasSkill(table, name))
      list.push("skill." + name)
    if (!on && list.includes("skills"))
      list = list.filter(item => item !== "skills").concat(skillNames.filter(other => other !== name).map(other => "skill." + other))
    if (!on)
      list = list.filter(item => item !== "skill." + name)
    const named = list.some(item => item.startsWith("skill."))
    if (named && !list.includes("skill") && !list.includes("skills"))
      list.push("skill")
    if (!named && !list.includes("skills"))
      list = list.filter(item => item !== "skill")
    return Object.assign({}, table, { [key]: list })
  }

  // `table` with every skill by the skills group (`on`), or with none.
  function withAllSkills(table, on) {
    const key = hasKey(table)
    const list = (table[key] || []).filter(item => item !== "skills" && item !== "skill" && !item.startsWith("skill."))
    return Object.assign({}, table, { [key]: on ? list.concat(["skills"]) : list })
  }

  // The agents of the project on screen that have the tool or skill `name` in
  // any of its places, by its overview.
  function holders(name) {
    const overview = overviews[project]
    if (!overview || overview.error)
      return []
    const names = new Set()
    for (const place of overview.places)
      for (const entry of place.depths)
        for (const agent of entry.stages.map(stage => stage.agent).concat(entry.agents))
          if (agent.tools.some(tool => tool.state === "have" && (tool.name === name || (tool.members || []).includes(name))))
            names.add(agent.name)
    return [...names].sort()
  }

  // The project's catalog, as the tools tool prints it: {tools, mcp}; null
  // until it answers.
  property var catalog: null
  function loadCatalog() {
    call("POST", "/v1/cli", { argv: ["tools"] }, false, data => catalog = JSON.parse(data.output))
  }

  // Project id -> the project as it runs in each of its workspaces, as the
  // overview tool prints it, read from that project's own socket.
  property var overviews: ({})
  function loadOverviews() {
    call("GET", "/v1/projects", null, false, data => {
      projects = data.items
      for (const each of projects)
        http.call(each.socket, "POST", "/v1/cli", { argv: ["overview"] }, false, data => {
          overviews = Object.assign({}, overviews, { [each.id]: JSON.parse(data.output) })
        }, reason => overviews = Object.assign({}, overviews, { [each.id]: { error: reason } }))
    })
  }

  // One HTTP request on the project's socket, as `Http.call` makes it.
  function call(method, path, body, idempotent, done, failed) {
    http.call(socket, method, path, body, idempotent, done, failed)
  }

  Http {
    id: http
    onRefused: reason => root.tell(reason, true)
  }
}
