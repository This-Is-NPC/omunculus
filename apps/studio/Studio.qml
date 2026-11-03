pragma Singleton
import QtQuick
import Quickshell
import "kit/client"
import "kit/ui"

// Studio is the project as its settings see it: whether the server answers,
// its setup, catalog and passwords, and every project of the registry as its
// overview tool prints it. Every read and write goes to the server's local
// socket through curl, the config through the typed /v1 routes.
Singleton {
  id: root

  // Once the server answers, everything the settings show is read.
  Project {
    id: client
    onReached: {
      root.loadSetup()
      root.loadMembers()
      root.loadUsage()
      root.loadOmapass()
      root.loadOverviews()
      root.loadCatalog()
    }
  }
  property alias socket: client.socket
  property alias project: client.project
  property alias connected: client.connected
  property alias message: client.message
  property alias messageIsError: client.messageIsError
  property alias noticeCount: client.noticeCount
  readonly property Http http: client.http
  // The project's setup, as GET /v1/projects/{id}/config?whole=true gives it: {root, agents, models,
  // workspaces, workspace, workflows, document, literal_keys, revision, names};
  // null until it answers.
  property var setup: null

  function tell(text, isError) { client.tell(text, isError) }

  // The file of an agent's image, as a url, or "" while it has none or it
  // is being fetched.
  function imageOf(agent) { return images.source(agent) }
  AgentImages {
    id: images
    http: root.http
    socket: root.socket
    base: client.base
    agents: root.setup ? root.setup.agents : []
  }

  function loadSetup() {
    http.setup(socket, project, read => setup = read)
  }

  // An agent's colour, by its place among the setup's agents.
  function toneOf(name) { return Theme.agentTone(setup ? setup.agents : [], name) }

  // Every project of the server's registry, the one on screen among them, as
  // {id, socket}, as GET /v1/projects lists them on this socket.
  property var projects: []

  // Adds the project `id`, whose config is the file at `config`, to the
  // running server, then reads every project again. `failed` gets the reason.
  function registerProject(id, config, done, failed) {
    client.call("POST", "/v1/projects", { id: id, config: config }, false, () => {
      loadOverviews()
      done()
    }, failed)
  }

  // Writes one item of the config ("agents.worker", "policy") with PUT, or
  // removes it with DELETE for a null value, renaming `from` when given; then
  // reads the setup again. `failed` gets the server's reason.
  function configure(item, value, from, done, failed) {
    const dot = item.indexOf(".")
    const section = dot < 0 ? item : item.slice(0, dot)
    let path = "/v1/projects/" + encodeURIComponent(project) + "/config/" + section
    if (dot >= 0)
      path += "/" + encodeURIComponent(item.slice(dot + 1))
    let method = "DELETE"
    let body = null
    if (value === null) {
      path += "?revision=" + setup.revision
    } else {
      method = "PUT"
      body = { revision: setup.revision, value: value }
      if (from)
        body.from = from
    }
    http.call(socket, method, path, body, false, () => {
      loadSetup()
      loadOverviews()
      done()
    }, reason => {
      loadSetup()
      failed(reason)
    })
  }

  // The project's members, as GET .../members lists them: [{issuer, subject,
  // role, updated_at}]; null until it answers, or while this window may not
  // manage the project's access.
  property var members: null
  function loadMembers() {
    client.call("GET", client.base + "/members", null, false, data => members = data.items, () => members = null)
  }

  // Assigns `role` to the member, or removes the member for a null role; then
  // reads the members again. `failed` gets the server's reason.
  function setMember(issuer, subject, role, done, failed) {
    const done_ = () => {
      loadMembers()
      done()
    }
    if (role === null)
      client.call("DELETE", client.base + "/members/" + encodeURIComponent(issuer) + "/" + encodeURIComponent(subject), null, false, done_, failed)
    else
      client.call("POST", client.base + "/members", { issuer: issuer, subject: subject, role: role }, false, done_, failed)
  }

  // What the project's model replies used, as GET .../usage gives it:
  // {agents: [{agent, model, replies, input, cached, output, cost}], total};
  // null until it answers, or while this window may not manage the config.
  property var usage: null
  function loadUsage() {
    client.call("GET", client.base + "/usage", null, false, data => usage = data, () => usage = null)
  }

  // Sends one short prompt to the model `name` as `value` would make it, and
  // hands its {reply, ms}, or the reason it failed.
  function testModel(name, value, done, failed) {
    http.command(socket, "model_test", { name: name, value: JSON.stringify(value) }, output => done(JSON.parse(output)), failed)
  }

  // Whether omapass is installed, its program and its passwords, as the omapass
  // tool prints them; null until it answers.
  property var omapass: null
  function loadOmapass() {
    http.command(socket, "omapass", {}, output => omapass = JSON.parse(output))
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

  // The agents of the stages of every workflow a depth of an overview's
  // place may go through.
  function staged(entry) {
    return entry.workflows.reduce((all, workflow) => all.concat(workflow.stages.map(stage => stage.agent)), [])
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
        for (const agent of staged(entry).concat(entry.agents))
          if (agent.tools.some(tool => tool.state === "have" && (tool.name === name || (tool.members || []).includes(name))))
            names.add(agent.name)
    return [...names].sort()
  }

  // The project's catalog, as the tools tool prints it: {tools, mcp}; null
  // until it answers.
  property var catalog: null
  function loadCatalog() {
    http.command(socket, "tools", {}, output => catalog = JSON.parse(output))
  }

  // Project id -> the project as it runs in each of its workspaces, as the
  // overview tool prints it, read from that project's own socket.
  property var overviews: ({})
  // Project id -> the packs it imports, as its config route lists them.
  property var packsOf: ({})
  function loadOverviews() {
    client.call("GET", "/v1/projects", null, false, data => {
      projects = data.items
      for (const each of projects) {
        http.command(each.socket, "overview", { whole: true }, output => {
          overviews = Object.assign({}, overviews, { [each.id]: JSON.parse(output) })
        }, reason => overviews = Object.assign({}, overviews, { [each.id]: { error: reason } }))
        http.setup(each.socket, each.id, read => packsOf = Object.assign({}, packsOf, { [each.id]: read.packs }), () => {})
      }
    })
  }
}
