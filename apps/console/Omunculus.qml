pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Requests.js" as Requests
import "kit/ui"

// Omunculus is the project as the window sees it: whether the server answers,
// its conversations, and the one on screen folded into threads a person can
// follow. The main thread is yours with the root agent; each work handed down
// has a thread of its own, where its agent says and does what it does. A run
// at depth 0 belongs to the main thread, a deeper one to its work's. Every read and command goes to the server's local
// socket through curl; the event stream is the conversation's WebSocket.
Singleton {
  id: root

  readonly property string socket: Quickshell.env("OMUNCULUS_SOCKET")
  readonly property string project: Quickshell.env("OMUNCULUS_PROJECT")
  readonly property string base: "/v1/projects/" + project
  // Every project of the server's registry, the one on screen among them, as
  // {id, socket}.
  // {id, socket}, as GET /v1/projects lists them on this socket.
  property var projects: []

  property bool connected: false
  // "start", "history", or "" while a conversation is on screen.
  property string view: "start"
  property var conversations: []
  // Conversation id -> {title, running, waiting}, read from its snapshot.
  property var summaries: ({})
  property string conversationId: ""
  readonly property var conversation: conversations.find(item => item.id === conversationId) || null
  readonly property string title: conversationId === "" ? "" : (summaries[conversationId] || {}).title || "new conversation"
  property var works: []
  property var runs: []
  property var requests: []
  property var inbox: []
  // The latest event cursor of the open conversation; the stream resumes after it.
  property string cursor: ""
  property bool streaming: false
  // While the history of the conversation opened is read in.
  property bool replaying: false
  // Thread key ("" or a work id) -> its ListModel. Each entry: kind (speech,
  // turn or request), key, who, text, mine, stamp, at (seconds), work,
  // streaming, partial (the text its model is writing), steps (JSON), and
  // fresh: it arrived while the conversation was open, rather than with its
  // history. A turn is one run of an agent: what it said and what it did.
  // Every request and every note to you also shows in the main thread, where
  // it was made.
  property var threads: ({})
  // Run id -> {thread, row}.
  property var rows: ({})
  // Work id -> the work it was handed down from, and run id -> its thread.
  property var parentOf: ({})
  property var runThread: ({})
  // Work id ("" for runs without one) -> the tool its agent called last.
  property var calling: ({})
  // Inbox id -> the text its notify event carried, request id -> the reason
  // its request event carried, and request id -> how it was answered
  // ({option, who, body}); the snapshot has none of them.
  property var notes: ({})
  property var reasons: ({})
  property var replies: ({})
  // The project's setup, as the config tool prints it: {root, agents, models,
  // workspaces, workspace, workflows}, and for the settings {document,
  // literal_keys, revision, names}; null until it answers.
  property var setup: null
  // What the open conversation's model calls used, as their providers reported
  // it: {calls, input, cached, output, cost, priced}, in all and by agent. Shown
  // only when asked for.
  property var usage: ({ all: tally(), agents: {} })
  // Every event of the open conversation, oldest first, as a line of its log:
  // {id, at, time, type, who, run, work, what, event}.
  property var log: []
  // The lines of the history while it is read in, given to `log` at once.
  property var logBuffer: []

  // Agent name -> its colour, in the order agents first appear.
  property var tones: ({})

  property string message: ""
  property bool messageIsError: false
  property int noticeCount: 0

  readonly property var running: runs.filter(run => run.status === "open")
  readonly property var waiting: requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter))
  readonly property var unread: inbox.filter(item => !item.read_at)
  // What waits on you: requests to decide and notes to read.
  readonly property int pending: waiting.length + unread.length
  // Requests still waiting, on you or on an agent.
  readonly property var asking: requests.filter(request => Requests.pending(request))


  Component.onCompleted: {
    if (socket === "" || project === "")
      tell("OMUNCULUS_SOCKET and OMUNCULUS_PROJECT are not set; start through apps/kit/run console", true)
    else
      check()
  }

  // Whether the server answers, asked again every few seconds.
  function check() {
    call("GET", "/v1/identity", null, false, () => {
      if (!connected) {
        connected = true
        loadConversations()
        loadSetup()
      }
    }, () => connected = false)
  }
  Timer { interval: 5000; repeat: true; running: root.socket !== ""; onTriggered: root.check() }

  function tell(text, isError) {
    message = text
    messageIsError = isError
    noticeCount++
  }

  // copy puts text on the Wayland clipboard, as it is, and says so.
  function copy(text) {
    clipboard.command = ["wl-copy", "--", text]
    clipboard.startDetached()
    tell("copied", false)
  }
  Process { id: clipboard }

  // Reads the project's setup through the config tool on the local socket.
  function loadSetup() {
    call("POST", "/v1/cli", { argv: ["config"] }, false, data => setup = JSON.parse(data.output))
  }

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

  // Whether the settings window is open.
  property bool settingsOpen: false
  function toggleSettings() {
    if (settingsOpen)
      settingsOpen = false
    else
      openSettings()
  }

  function openSettings() {
    settingsOpen = true
    loadSetup()
    loadOmapass()
    loadOverviews()
    loadCatalog()
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

  // The model id an agent runs on, as configured, or "" before the setup.
  function modelOf(agent) {
    if (!setup)
      return ""
    const configured = setup.agents.find(item => item.name === agent)
    const model = configured ? setup.models.find(item => item.name === configured.model) : null
    return model ? model.model || model.name : configured ? configured.model : ""
  }

  // A workspace by name, or the default one for "", as {name, root}; the
  // project root when there is none.
  function workspaceOf(name) {
    if (!setup)
      return { name: "", root: "" }
    const wanted = name || setup.workspace
    return setup.workspaces.find(item => item.name === wanted) || { name: "", root: setup.root }
  }

  function loadConversations() {
    call("GET", base + "/conversations", null, false, data => {
      conversations = data.items.slice().sort((a, b) => b.created_at.localeCompare(a.created_at))
      summarize(conversations.map(item => item.id))
    })
  }

  // Reads each conversation's snapshot in turn, for its line in the history.
  function summarize(ids) {
    if (ids.length === 0)
      return
    call("GET", base + "/conversations/" + ids[0] + "/snapshot", null, false, data => {
      const next = Object.assign({}, summaries)
      next[ids[0]] = summary(data)
      summaries = next
      summarize(ids.slice(1))
    }, () => summarize(ids.slice(1)))
  }

  function summary(data) {
    const said = data.prompts.find(prompt => prompt.kind === "message")
    return {
      title: said ? String(said.body).replace(/\s+/g, " ") : "",
      running: data.runs.filter(run => run.status === "open").length,
      waiting: data.requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter)).length
    }
  }

  function openHistory() {
    view = "history"
    loadConversations()
  }

  function createConversation() {
    call("POST", base + "/conversations", {}, true, data => {
      loadConversations()
      open(data.id)
    })
  }

  function open(id) {
    conversationId = id
    view = ""
    cursor = ""
    rows = {}
    parentOf = {}
    runThread = {}
    calling = {}
    threads = {}
    notes = {}
    reasons = {}
    replies = {}
    tones = {}
    usage = { all: tally(), agents: {} }
    works = []
    runs = []
    requests = []
    inbox = []
    log = []
    logBuffer = []
    streamLink.active = false
    // The history comes in one read, before the stream resumes after it.
    call("GET", base + "/conversations/" + id + "/events", null, false, data => {
      if (id !== conversationId)
        return
      replaying = true
      data.events.forEach(handle)
      replaying = false
      log = logBuffer
      logBuffer = []
      refresh()
      connectStream()
    })
  }

  // leave goes back to the conversations; the agents go on without the window.
  function leave() {
    conversationId = ""
    streamGeneration++
    streamLink.active = false
    streaming = false
    threads = {}
    openHistory()
  }

  function refresh() {
    if (conversationId === "")
      return
    const id = conversationId
    call("GET", base + "/conversations/" + id + "/snapshot", null, false, data => {
      if (id !== conversationId)
        return
      works = data.works
      runs = data.runs
      requests = data.requests
      inbox = data.inbox
      meet(works.map(work => work.assignee))
      const next = Object.assign({}, summaries)
      next[id] = summary(data)
      summaries = next
    })
  }

  // A message to the root agent, or, with a work, to that work's agent.
  function send(text, work) {
    const value = text.trim()
    if (value === "" || conversationId === "")
      return
    const body = { message: value }
    if (work)
      body.work_id = work
    call("POST", base + "/conversations/" + conversationId + "/messages", body, true, () => {})
  }

  // A note on a work: context its agents read, not a new run.
  function note(text, work) {
    const value = text.trim()
    if (value === "" || !work)
      return
    call("POST", base + "/conversations/" + conversationId + "/comments", { body: value, work_id: work }, true, () => tell("noted", false))
  }

  function reply(requestId, option, body) {
    call("POST", base + "/conversations/" + conversationId + "/requests/" + requestId + "/reply",
      Requests.answer(option, body), true, () => tell(option ? "replied " + option : "replied", false))
  }

  function markRead(inboxId) {
    call("POST", base + "/conversations/" + conversationId + "/inbox/" + inboxId + "/read", {}, true, () => refresh())
  }

  function work(id) {
    return works.find(item => item.id === id) || null
  }

  // The works under `id` in tree order, each with its depth below it; `id`
  // itself first when `self`, and "" for every work of the conversation.
  function tree(id, self) {
    const ordered = []
    const visit = (parent, level) => works
      .filter(item => (item.parent_id || "") === parent)
      .forEach(item => { ordered.push({ work: item, level: level }); visit(item.id, level + 1) })
    const top = self ? work(id) : null
    if (top)
      ordered.push({ work: top, level: 0 })
    visit(id, top ? 1 : 0)
    return ordered
  }

  // Whether an agent is running on the work now ("" for runs without one),
  // the requests it made that still wait, and the notes from it you have not read.
  function busy(id) { return running.some(run => (run.work_id || "") === id) }
  function asked(id) { return asking.filter(request => (request.work_id || "") === id) }
  function unreadFrom(id) { return unread.filter(item => (item.work_id || "") === id) }

  // The thread of a work: its own when it was handed down, the main one for a
  // work the root agent opened for itself.
  function threadOf(work) {
    return work && parentOf[work] !== undefined ? work : ""
  }

  // The model of a thread; an empty one until the thread has entries.
  function thread(key) {
    return threads[key] || empty
  }
  property ListModel empty: ListModel {}
  Component { id: threadModel; ListModel {} }

  // The colour of a work's state: open in the accent, done, broken, cancelled,
  // and waiting in the warning colour.
  function stateTone(state) {
    return { open: Theme.primary, done: Theme.success, cancelled: Theme.dim, broken: Theme.error }[state] || Theme.warning
  }

  function toneOf(name) {
    return name === "you" ? Theme.primary : tones[name] || Theme.dim
  }

  // Gives each agent its colour the first time the window meets it.
  function meet(names) {
    const fresh = names.filter(name => name && name !== "you" && tones[name] === undefined)
    if (fresh.length === 0)
      return
    const next = Object.assign({}, tones)
    for (const name of fresh)
      next[name] = Theme.agentPalette[Object.keys(next).length % Theme.agentPalette.length]
    tones = next
  }

  // The message text a model event carries: a plain string, an OpenAI or
  // Anthropic message, or a Responses output; a tool call alone has none.
  function text(body) {
    if (typeof body === "string")
      return body
    if (body === null || typeof body !== "object" || body.type === "call")
      return ""
    if (typeof body.content === "string")
      return body.content
    for (const key of ["content", "output"]) {
      if (Array.isArray(body[key]))
        return body[key].map(part => typeof part.text === "string" ? part.text : text(part)).filter(part => part !== "").join("\n")
    }
    return ""
  }

  // Streamed Markdown with its open marks closed — a fence, bold, inline
  // code — or dropped when nothing follows them yet.
  function closed(text) {
    if ((text.match(/^```/gm) || []).length % 2)
      return text + "\n```"
    let shown = text.replace(/\s+$/, "")
    const open = ["**", "`"].filter(mark => shown.split(mark).length % 2 === 0)
      .map(mark => ({ mark: mark, at: shown.lastIndexOf(mark) }))
      .sort((a, b) => b.at - a.at)
    for (const left of open)
      shown = shown.slice(left.at + left.mark.length).trim() === "" ? shown.slice(0, left.at).replace(/\s+$/, "") : shown + left.mark
    return shown
  }

  // Text as Markdown should show it: without inline code marks, which would
  // set it in a larger font, and with each line break kept.
  function inline(text) {
    return text.replace(/`([^`\n]+)`/g, "$1").replace(/([^\n])\n(?!\n)/g, "$1  \n")
  }

  function brief(args) {
    const parts = Object.keys(args || {}).map(key => {
      const value = typeof args[key] === "string" ? args[key] : JSON.stringify(args[key])
      return key + ": " + value
    })
    const line = parts.join("  ·  ").replace(/\s+/g, " ")
    return line.length > 120 ? line.slice(0, 117) + "..." : line
  }

  // The event as a line of the log; while the history is read in, kept aside.
  function record(event) {
    const body = event.body || {}
    const line = {
      id: event.cursor || event.at + event.type,
      at: event.at,
      time: event.at.slice(11, 23),
      type: event.type,
      who: event.type === "start-run" ? body.agent || "" : actorName(event.actor),
      run: event.run_id || "",
      work: event.work_id || "",
      what: what(event.type, body),
      event: event
    }
    if (replaying)
      logBuffer.push(line)
    else
      log = log.concat([line])
  }

  // What an event says, on one line.
  function what(type, body) {
    const line = value => String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim()
    const json = value => line(JSON.stringify(value))
    switch (type) {
    case "prompt":
      return line(body.message)
    case "comment":
      return line(body.body)
    case "model":
      return line(text(body)) || json(body)
    case "tool":
      return (body.via ? body.via + " → " : "") + body.name + " " + json(body.args || {}) + (body.ok ? "  ok" : "  failed")
        + (body.output ? "  ·  " + (typeof body.output === "string" ? line(body.output) : json(body.output)) : "")
    case "start-run":
      return (body.agent || "") + (body.depth !== undefined ? " at depth " + body.depth : "") + (body.via ? " via " + body.via : "")
    case "end-run":
      return ""
    default:
      return json(body)
    }
  }

  function actorName(actor) {
    if (!actor)
      return ""
    return actor.kind === "agent" ? actor.id : "you"
  }

  function append(key, entry) {
    if (!threads[key]) {
      const next = Object.assign({}, threads)
      next[key] = threadModel.createObject(root)
      threads = next
    }
    const model = threads[key]
    model.append(Object.assign({
      kind: "speech", key: "", who: "", text: "", mine: false, stamp: "", at: 0, work: "",
      streaming: false, partial: "", steps: "[]",
      fresh: !replaying
    }, entry))
    return { thread: key, row: model.count - 1 }
  }

  function entryAt(place) { return threads[place.thread].get(place.row) }
  function update(place, role, value) { threads[place.thread].setProperty(place.row, role, value) }

  function keep(map, key, value) {
    const next = Object.assign({}, root[map])
    next[key] = value
    root[map] = next
  }



  function tally() {
    return { calls: 0, input: 0, cached: 0, output: 0, cost: 0, priced: 0 }
  }

  // Adds one model call's reported usage to the conversation's and its agent's.
  function count(who, reported) {
    const add = into => {
      into.calls++
      into.input += reported.prompt_tokens || reported.input_tokens || 0
      into.cached += (reported.prompt_tokens_details || reported.input_tokens_details || {}).cached_tokens || 0
      into.output += reported.completion_tokens || reported.output_tokens || 0
      if (typeof reported.cost === "number") {
        into.cost += reported.cost
        into.priced++
      }
    }
    const next = { all: Object.assign({}, usage.all), agents: Object.assign({}, usage.agents) }
    next.agents[who] = Object.assign(tally(), next.agents[who] || {})
    add(next.all)
    add(next.agents[who])
    usage = next
  }

  // Adds a line to the turn of the run it happened in.
  function step(runId, line) {
    const place = rows[runId]
    if (place === undefined)
      return
    const steps = JSON.parse(entryAt(place).steps)
    steps.push(line)
    update(place, "steps", JSON.stringify(steps))
  }

  // Adds what was said to the turn of its run, or as a line of its own in `key`.
  function say(key, runId, who, said, stamp, at) {
    const place = rows[runId]
    if (place === undefined) {
      append(key, { who: who, mine: who === "you", text: said, stamp: stamp, at: at })
      return
    }
    const before = entryAt(place).text
    update(place, "text", before === "" ? said : before + "\n\n" + said)
  }

  function handle(event) {
    if (event.type === "run.delta") {
      const place = rows[event.run_id]
      if (place !== undefined)
        update(place, "partial", entryAt(place).partial + event.text)
      return
    }
    if (event.cursor)
      cursor = event.cursor
    record(event)
    const body = event.body || {}
    const who = actorName(event.actor)
    const stamp = event.at.slice(11, 16)
    const at = Date.parse(event.at) / 1000
    const work = event.work_id || ""
    if (event.type === "delegate" && work)
      keep("parentOf", work, body.parent_id || "")
    if (event.type === "start-run")
      keep("runThread", event.run_id, Number(body.depth) > 0 && work ? work : "")
    // Where the event shows: its run's thread, else its work's.
    const key = runThread[event.run_id] !== undefined ? runThread[event.run_id] : threadOf(work)
    meet([who, body.agent])
    switch (event.type) {
    case "prompt":
      append(key, { who: "you", mine: true, text: body.message || "", stamp: stamp, at: at })
      break
    case "comment":
      if (body.body)
        say(key, event.run_id, who, body.body, stamp, at)
      break
    case "model": {
      if (body.usage)
        count(who, body.usage)
      const said = text(body)
      const place = rows[event.run_id]
      if (place !== undefined)
        update(place, "partial", "")
      if (said !== "")
        say(key, event.run_id, who, said, stamp, at)
      break
    }
    case "start-run":
      keep("rows", event.run_id, append(key, { kind: "turn", key: event.run_id, who: body.agent, work: work, streaming: true, stamp: stamp, at: at }))
      break
    case "end-run": {
      const place = rows[event.run_id]
      if (place !== undefined) {
        update(place, "streaming", false)
        update(place, "partial", "")
      }
      break
    }
    case "tool": {
      // The prompt, the end and the chained steps have entries of their own;
      // a hook, called with the event alone, shows only when it fails.
      const hook = body.args && typeof body.args.event === "object" && Object.keys(body.args).length === 1
      if (!["assemble", "send", "end"].includes(body.name) && !body.via && !(hook && body.ok !== false)) {
        step(event.run_id, { name: body.name, ok: body.ok !== false, text: hook ? "" : brief(body.args), output: body.ok === false ? String(body.output || "") : "", outcome: false })
        keep("calling", work, body.name)
      }
      break
    }
    case "continue":
      step(event.run_id, { name: "continue", ok: true, text: body.to ? "moved the work to " + body.to : "closed the work", output: "", outcome: true })
      break
    case "grant":
      step(event.run_id, { name: "grant", ok: true, text: "granted " + body.name + (body.scope ? " for the " + body.scope : " for this work"), output: "", outcome: true })
      break
    case "request":
      keep("reasons", event.request_id, body.reason || "")
      append("", { kind: "request", key: event.request_id, who: who, stamp: stamp, at: at, work: work })
      break
    case "reply":
      keep("replies", event.request_id, { option: body.option, who: who, body: body.body || "" })
      break
    case "notify":
      if (event.inbox_id)
        keep("notes", event.inbox_id, body.body || "")
      append("", { who: who, text: body.body || "", stamp: stamp, at: at, work: work })
      break
    }
    if (!replaying)
      refreshTimer.restart()
  }

  // Splits the stream's bytes into the JSON objects its frames carry: curl
  // writes each frame's payload as it comes, with nothing between them.
  // `buffer` starts at the object being read; `scanned` characters of it
  // have been read with the depth and string state below. The scan runs on
  // locals: reading a property converts its whole string on every access.
  property string buffer: ""
  property int scanned: 0
  property int scanDepth: 0
  property bool scanString: false
  property bool scanEscape: false
  function feed(data) {
    const text = buffer + data
    let depth = scanDepth
    let inString = scanString
    let escaped = scanEscape
    let start = 0
    for (let i = scanned; i < text.length; i++) {
      const c = text[i]
      if (inString) {
        if (escaped)
          escaped = false
        else if (c === "\\")
          escaped = true
        else if (c === "\"")
          inString = false
      } else if (c === "\"") {
        inString = true
      } else if (c === "{") {
        if (depth === 0)
          start = i
        depth++
      } else if (c === "}") {
        depth--
        if (depth === 0) {
          handle(JSON.parse(text.slice(start, i + 1)))
          start = i + 1
        }
      }
    }
    buffer = text.slice(depth === 0 ? text.length : start)
    scanned = buffer.length
    scanDepth = depth
    scanString = inString
    scanEscape = escaped
  }

  // Each connection is a new process; a stream that ends while its
  // conversation is still open connects again after a second.
  property int streamGeneration: 0
  function connectStream() {
    streamGeneration++
    buffer = ""
    scanned = 0
    scanDepth = 0
    scanString = false
    scanEscape = false
    streamLink.active = false
    streamLink.active = conversationId !== ""
  }

  Loader {
    id: streamLink
    active: false
    sourceComponent: Process {
      readonly property int generation: root.streamGeneration
      command: ["curl", "-sN", "--unix-socket", root.socket,
        "ws://localhost" + root.base + "/conversations/" + root.conversationId + "/stream" + (root.cursor !== "" ? "?after=" + root.cursor : "")]
      running: true
      stdout: SplitParser {
        splitMarker: ""
        onRead: data => root.feed(data)
      }
      onRunningChanged: if (generation === root.streamGeneration) root.streaming = running
      onExited: if (generation === root.streamGeneration) reconnect.restart()
    }
  }

  Timer {
    id: reconnect
    interval: 1000
    onTriggered: root.connectStream()
  }

  Timer {
    id: refreshTimer
    interval: 250
    onTriggered: root.refresh()
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
