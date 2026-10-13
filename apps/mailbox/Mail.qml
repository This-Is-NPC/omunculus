pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "kit/client"
import "kit/client/Requests.js" as Requests

// Mail is every project of the server as the mailbox sees it. A thread is a
// conversation with one agent of depth 0: what you write goes to that agent,
// and what it says comes back. Its questions and approvals for you, the
// requests whose arbiter you are, show in the thread too. Every read and
// command goes to a project's local socket through curl.
Singleton {
  id: root

  // The socket the mailbox was opened on; it lists every project.
  readonly property string socket: Quickshell.env("OMUNCULUS_SOCKET")

  property bool connected: false
  // You, as the server knows you: {issuer, subject}.
  property var me: null
  // Every project, as {id, socket, agents}: the agents of depth 0 a thread
  // can be with.
  property var projects: []
  // "project/conversation" -> its thread: {key, project, id, agent, subject,
  // working, waiting, status, at, heard, snippet, entries}.
  property var threads: ({})
  // A thread with nothing in it, for a view whose thread has just gone.
  readonly property var blank: ({ key: "", project: "", id: "", agent: "", subject: "", working: false,
    waiting: [], status: { state: "idle", label: "", brief: "", line: "", next: "" }, at: "", heard: "", snippet: "", entries: [] })
  // Newest first.
  readonly property var all: Object.values(threads).sort((a, b) => b.at.localeCompare(a.at))
  // "all", "waiting" (a decision of yours) or "working" (a run open).
  property string folder: "all"
  // A project id, or "" for every project.
  property string project: ""
  // What the search box asks for, lowercased; "" finds every thread.
  property string query: ""
  readonly property var shown: all.filter(thread => (project === "" || thread.project === project)
    && (folder === "all" || (folder === "waiting" ? thread.waiting.length > 0 : thread.working))
    && matches(thread))
  property string selected: ""
  readonly property var thread: threads[selected] || null
  // Asks the window for a new thread, and the thread on screen for a reply or
  // for the decision it waits on.
  signal composeRequested()
  signal replyRequested()
  signal decisionRequested()

  // Thread key -> the time of the last word from its agent you read; kept
  // across sessions.
  property var seen: ({})
  readonly property int unread: all.filter(thread => isUnread(thread)).length
  readonly property int waiting: all.filter(thread => thread.waiting.length > 0).length
  readonly property int working: all.filter(thread => thread.working).length

  property string message: ""
  property bool messageIsError: false

  // Thread key -> {cursor, events, snapshot}: what its thread is built from.
  property var cache: ({})
  property bool sweeping: false
  // After the first sweep, a new word from an agent is announced on the desktop.
  property bool primed: false

  Component.onCompleted: {
    if (socket === "")
      tell("OMUNCULUS_SOCKET is not set; start through apps/kit/run mailbox", true)
    else
      sweep()
  }

  Timer { interval: 2500; repeat: true; running: root.socket !== ""; onTriggered: root.sweep() }

  function tell(text, isError) {
    message = text
    messageIsError = isError
  }

  // Whether a thread holds what the search asks for: in its subject, agent,
  // project, any of its messages or the names of their files.
  function matches(thread) {
    if (query === "")
      return true
    const words = [thread.subject, thread.agent, thread.project]
      .concat(thread.entries.map(entry => entry.text), thread.entries.reduce((names, entry) => names.concat(entry.files.map(file => file.name)), []))
    return words.some(word => String(word).toLowerCase().includes(query))
  }

  // The day a thread belongs to in the list: today, yesterday or its date.
  function day(at) {
    const date = new Date(at)
    if (isNaN(date))
      return ""
    const today = new Date()
    const yesterday = new Date(today.getTime() - 86400000)
    return date.toDateString() === today.toDateString() ? "today"
      : date.toDateString() === yesterday.toDateString() ? "yesterday"
      : Qt.formatDate(date, "d MMMM yyyy")
  }

  function isUnread(thread) {
    return thread.heard !== "" && (seen[thread.key] || "") < thread.heard
  }

  function projectOf(id) {
    return projects.find(item => item.id === id) || null
  }

  function open(key) {
    selected = key
    markSeen(key)
  }

  function close() {
    selected = ""
  }

  // Opens the thread `by` places from the one open in the list shown.
  function step(by) {
    if (shown.length === 0)
      return
    const at = shown.findIndex(thread => thread.key === selected)
    open(shown[Math.max(0, Math.min(shown.length - 1, at < 0 ? 0 : at + by))].key)
  }

  // Marks a thread unread, as a mail client does, and goes back to the list.
  function markUnread(key) {
    seen = Object.assign({}, seen, { [key]: "" })
    seenFile.setText(JSON.stringify(seen))
    if (selected === key)
      close()
  }

  // Marks every thread shown read.
  function markAllRead() {
    const next = Object.assign({}, seen)
    for (const thread of shown)
      if (thread.heard !== "")
        next[thread.key] = thread.heard
    seen = next
    seenFile.setText(JSON.stringify(seen))
    tell("marked " + shown.length + " threads read", false)
  }

  function markSeen(key) {
    const thread = threads[key]
    if (!thread || !isUnread(thread))
      return
    seen = Object.assign({}, seen, { [key]: thread.heard })
    seenFile.setText(JSON.stringify(seen))
  }

  // What arrives in the thread on screen is read as it arrives.
  onThreadsChanged: if (selected !== "") markSeen(selected)

  function compose() {
    composeRequested()
  }

  // A new thread: a conversation in `project` and your first message to
  // `agent` there, with the files at the paths `files` lists.
  function send(project, agent, text, files) {
    const value = text.trim()
    const place = projectOf(project)
    if (value === "" || !place || agent === "")
      return
    http.call(place.socket, "POST", "/v1/projects/" + project + "/conversations", {}, true, data => {
      http.post(place.socket, "/v1/projects/" + project + "/conversations/" + data.id + "/messages",
        { message: value, agent: agent }, files, () => {
          selected = project + "/" + data.id
          tell("sent to " + agent, false)
          sweep()
        })
    })
  }

  // Your next message in a thread, to its agent, with the files at the paths `files` lists.
  function reply(key, text, files) {
    const thread = threads[key]
    const value = text.trim()
    if (!thread || value === "")
      return
    http.post(projectOf(thread.project).socket, "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/messages",
      { message: value, agent: thread.agent }, files, () => {
        tell("sent to " + thread.agent, false)
        sweep()
      })
  }

  // Saves a file attached in a thread to the downloads directory and opens it.
  function openAttachment(key, file) {
    const thread = threads[key]
    if (!thread)
      return
    http.openAttachment(projectOf(thread.project).socket,
      "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/attachments/" + file.sha256, file)
    tell("opening " + file.name, false)
  }

  // Answers a request of a thread: an option it offers, text, or both.
  // Answers a request with words and an option, of the request itself or, by
  // the parts of path, of the decision below it that the option is of.
  function decide(key, requestId, option, body, path) {
    const thread = threads[key]
    if (!thread || (!option && body.trim() === ""))
      return
    http.call(projectOf(thread.project).socket, "POST",
      "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/requests/" + requestId + "/reply",
      Requests.answer(option, body.trim(), path), true, () => {
        tell(option ? "answered " + option : "answered", false)
        sweep()
      })
  }

  // Reads who you are and the projects, then every project's conversations; a
  // snapshot whose cursor moved brings its new events.
  function sweep() {
    if (sweeping)
      return
    sweeping = true
    const failed = () => {
      connected = false
      sweeping = false
    }
    http.call(socket, "GET", "/v1/identity", null, false, identity => {
      me = identity
      http.call(socket, "GET", "/v1/projects", null, false, data => {
        connected = true
        loadAgents(data.items)
        const pending = data.items.slice()
        const keys = []
        const nextProject = () => {
          if (pending.length === 0) {
            for (const key of Object.keys(threads))
              if (!keys.includes(key))
                forget(key)
            sweeping = false
            primed = true
            return
          }
          const place = pending.shift()
          http.call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations", null, false, list => {
            const ids = list.items.map(item => item.id)
            ids.forEach(id => keys.push(place.id + "/" + id))
            readAll(place, ids, nextProject)
          }, nextProject)
        }
        nextProject()
      }, failed)
    }, failed)
  }

  // The agents of depth 0 of each project not yet known, from its config.
  function loadAgents(items) {
    const known = projects.filter(item => items.some(other => other.id === item.id))
    projects = items.map(item => known.find(other => other.id === item.id) || { id: item.id, socket: item.socket, agents: [] })
    for (const item of items) {
      if (known.some(other => other.id === item.id))
        continue
      http.call(item.socket, "POST", "/v1/cli", { argv: ["config", "--whole", "true"] }, false, data => {
        const agents = JSON.parse(data.output).agents.filter(agent => agent.depth === 0 && !agent.workflow_only).map(agent => agent.name)
        projects = projects.map(other => other.id === item.id ? Object.assign({}, other, { agents: agents }) : other)
      })
    }
  }

  function forget(key) {
    const left = Object.assign({}, threads)
    delete left[key]
    threads = left
    delete cache[key]
  }

  function readAll(place, ids, done) {
    if (ids.length === 0)
      return done()
    const id = ids[0]
    const key = place.id + "/" + id
    const rest = () => readAll(place, ids.slice(1), done)
    const base = "/v1/projects/" + place.id + "/conversations/" + id
    http.call(place.socket, "GET", base + "/snapshot", null, false, snapshot => {
      const known = cache[key] || { cursor: "", events: [], snapshot: null }
      if (known.snapshot && known.snapshot.cursor === snapshot.cursor)
        return rest()
      events(place.socket, base, known.cursor, known.events, (cursor, all) => {
        cache[key] = { cursor: cursor, events: all, snapshot: snapshot }
        update(key, build(place.id, id, snapshot, all))
        rest()
      }, rest)
    }, rest)
  }

  // Every event after `cursor`, a page of up to 500 at a time.
  function events(on, base, cursor, read, done, failed) {
    http.call(on, "GET", base + "/events" + (cursor ? "?after=" + cursor : ""), null, false, data => {
      const all = read.concat(data.events)
      const last = data.events.length > 0 ? data.events[data.events.length - 1].cursor : cursor
      if (data.events.length === 500)
        events(on, base, last, all, done, failed)
      else
        done(last, all)
    }, failed)
  }

  function update(key, thread) {
    const before = threads[key]
    threads = Object.assign({}, threads, { [key]: thread })
    if (!primed || selected === key)
      return
    const broke = ["failed", "stalled"].includes(thread.status.state) && (!before || before.status.state !== thread.status.state)
    if (broke)
      announce(thread.agent + " · " + thread.status.label.toLowerCase(), thread.status.line)
    else if (thread.heard !== "" && (!before || before.heard < thread.heard))
      announce(thread.waiting.length > 0 ? thread.agent + " waits for you" : thread.agent + " · " + thread.subject, thread.snippet)
  }

  function announce(title, body) {
    notifier.command = ["notify-send", "-a", "omunculus", title, body]
    notifier.startDetached()
  }
  Process { id: notifier }

  // Whether a participant is you.
  function isMe(participant) {
    return !!participant && !!me && Requests.human(participant) && participant.issuer === me.issuer && participant.subject === me.subject
  }

  // The thread a conversation's snapshot and events make. Its entries, in
  // order: each message you wrote; each run of an agent of depth 0, as what it
  // said; and each request whose arbiter is you, the question of whoever
  // asked it when the harness passed it on, as when the agent left a question
  // unanswered, with the harness's sentence as its fine print.
  function build(projectId, id, snapshot, events) {
    const rootRuns = {}
    for (const run of snapshot.runs)
      if (String(run.depth) === "0")
        rootRuns[run.id] = run
    const entries = []
    const spoken = {}
    const replies = {}
    let agent = ""
    for (const event of events) {
      const body = event.body || {}
      if (event.type === "prompt" && event.actor && event.actor.kind === "human") {
        agent = agent || body.agent || ""
        entries.push({ kind: "you", key: event.cursor, from: "you", to: body.agent || agent, text: body.message || "", at: event.at, open: false, files: body.attachments || [] })
      } else if (event.type === "reply" && event.request_id) {
        replies[event.request_id] = { option: Requests.chosen(body), body: body.body || "" }
      } else if (rootRuns[event.run_id] && ["model", "comment", "attach"].includes(event.type)) {
        const words = (event.type === "model" ? text(body) : event.type === "comment" ? String(body.body || "") : String(body.note || "")).trim()
        const files = event.type === "attach" ? body.attachments || [] : []
        if (words === "" && files.length === 0)
          continue
        const run = rootRuns[event.run_id]
        agent = agent || run.agent
        if (spoken[run.id] === undefined) {
          spoken[run.id] = entries.length
          entries.push({ kind: "agent", key: run.id, from: run.agent, to: "you", text: words, at: event.at, open: run.status === "open", files: files })
        } else {
          const entry = entries[spoken[run.id]]
          entry.text = [entry.text, words].filter(part => part !== "").join("\n\n")
          entry.files = entry.files.concat(files)
        }
      }
    }
    const notes = noted(events)
    const asked = snapshot.requests.filter(request => isMe(request.arbiter))
    for (const request of asked) {
      const question = asking(request, notes)
      entries.push({
        kind: "request", key: request.id, from: question.from, to: "you",
        note: question.note,
        text: question.text, fine: question.fine, at: request.created_at, open: Requests.pending(request),
        files: [],
        choices: Requests.choices(request),
        origins: question.origins,
        answer: replies[request.id] || null
      })
    }
    entries.sort((a, b) => a.at.localeCompare(b.at))

    const first = entries.find(entry => entry.kind === "you")
    const subject = first ? String(first.text).trim().split("\n")[0] : ""
    const theirs = entries.filter(entry => entry.kind !== "you")
    const latest = entries.length > 0 ? entries[entries.length - 1] : null
    return {
      key: projectId + "/" + id,
      project: projectId,
      id: id,
      agent: agent,
      subject: subject.length > 90 ? subject.slice(0, 87) + "..." : subject || "(no message)",
      working: snapshot.runs.some(run => run.status === "open"),
      waiting: asked.filter(request => Requests.pending(request)).map(request => request.id),
      status: status(snapshot, events, asked.filter(request => Requests.pending(request)), agent, notes),
      at: latest ? latest.at : snapshot.conversation.created_at,
      heard: theirs.length > 0 ? theirs[theirs.length - 1].at : "",
      snippet: latest ? oneLine((latest.kind === "you" ? "you: " : "") + latest.text
        + (latest.files.length > 0 ? " [" + latest.files.map(file => file.name).join(", ") + "]" : "")) : "",
      entries: entries
    }
  }

  // What a thread's conversation is doing, from its snapshot and events, as
  // {state, label, brief, line, next}: "waiting" while a request of yours is
  // pending; "working" while a run of any depth is open, saying whose, on
  // which work and stage, the tool it calls now and, on a retry, how many
  // and why; "failed" when nothing runs and the last run ended with an
  // error; "held" while nothing runs and a request waits on someone else;
  // "stalled" when nothing runs, nothing is pending and a work is not over;
  // "done" when every work it began is done or cancelled; "idle" otherwise.
  // `brief` is for the list, `line` and `next` for the thread's head; a
  // request in `notes` is the harness's, not its requester's.
  function status(snapshot, events, pending, to, notes) {
    const agent = to || "the agent"
    const works = {}
    for (const work of snapshot.works)
      works[work.id] = work
    const ended = {}
    const calling = {}
    for (const event of events) {
      if (!event.run_id)
        continue
      const body = event.body || {}
      if (event.type === "end-run")
        ended[event.run_id] = body
      else if (event.type === "model")
        calling[event.run_id] = calls(body)
      else if (event.type === "tool" && calling[event.run_id])
        calling[event.run_id] = calling[event.run_id].filter((name, at, names) => name !== body.name || at !== names.indexOf(body.name))
    }
    const runs = snapshot.runs.slice().sort((a, b) => a.started_at.localeCompare(b.started_at))
    const on = run => {
      const work = works[run.work_id]
      return work ? ", on “" + work.title + "”" + (work.stage ? " at " + work.stage : "") + "," : ""
    }
    const failure = run => run && ended[run.id] && ended[run.id].error ? String(ended[run.id].error) : ""
    // The run before `run` on its work, and how many retries in a row lead to it.
    const before = run => runs.filter(other => other.work_id === run.work_id && other.started_at < run.started_at).pop() || null
    const retries = run => run && run.via === "retry" ? 1 + retries(before(run)) : 0

    if (pending.length > 0) {
      const request = pending[0]
      const question = asking(request, notes)
      const asks = (question.note ? "note: " : question.from + " asks: ") + oneLine(question.text || "a decision")
      return { state: "waiting", label: "WAITING ON YOU", brief: asks, line: asks + (pending.length > 1 ? "  (+" + (pending.length - 1) + " more)" : ""),
        next: "Nothing in this thread moves until you decide: DECIDE takes you to the question." }
    }

    const open = runs.filter(run => run.status === "open")
    if (open.length > 0) {
      const run = open[open.length - 1]
      const names = calling[run.id] || []
      const doing = names.length > 0 ? "calling " + names.join(", ") : "thinking"
      const tries = retries(run)
      const others = open.length > 1 ? "  (+" + (open.length - 1) + " more running)" : ""
      const why = failure(before(run))
      return { state: "working", label: tries > 0 ? "RETRYING (" + tries + ")" : "WORKING",
        brief: run.agent + " " + doing,
        line: run.agent + on(run) + " " + doing + others,
        next: tries > 0 ? "The try before failed" + (why ? ": " + why : "") + ". Once the retries run out, "
          + (works[run.work_id] && works[run.work_id].parent_id ? "the work goes back to whoever handed it down." : "you are asked to retry or cancel.") : "" }
    }

    const finished = runs.filter(run => run.status !== "open").sort((a, b) => String(a.finished_at || "").localeCompare(String(b.finished_at || "")))
    const last = finished.length > 0 ? finished[finished.length - 1] : null
    const error = failure(last)
    if (error !== "")
      return { state: "failed", label: "FAILED", brief: last.agent + ": " + oneLine(error),
        line: last.agent + on(last) + " failed: " + error,
        next: "Nothing runs now. Write to " + agent + " again to try once more." }

    const held = snapshot.requests.filter(request => Requests.pending(request))
    if (held.length > 0) {
      const who = Requests.label(held[0].arbiter)
      return { state: "held", label: "WAITING ON " + who.toUpperCase(), brief: who + " has a question to answer",
        line: Requests.label(held[0].requester) + " waits on " + who + ": " + oneLine(held[0].reason || ""), next: "" }
    }

    // With nothing running or pending, a work open, or waiting, waits on nothing.
    const stuck = snapshot.works.find(work => work.state === "open") || snapshot.works.find(work => work.state === "waiting")
    if (stuck) {
      const by = runs.filter(run => run.work_id === stuck.id).pop()
      const who = by ? by.agent : stuck.assignee || "its agent"
      return { state: "stalled", label: "STALLED", brief: who + " stopped on “" + stuck.title + "”",
        line: who + " stopped on “" + stuck.title + "”" + (stuck.stage ? " · " + stuck.stage : "") + " without finishing it, and nothing runs now.",
        next: "Write to " + agent + " again to pick it up." }
    }

    const roots = snapshot.works.filter(work => !work.parent_id)
    if (roots.length > 0 && roots.every(work => work.state === "done" || work.state === "cancelled"))
      return { state: "done", label: roots.every(work => work.state === "cancelled") ? "CANCELLED" : "DONE", brief: "", line: "", next: "" }
    return { state: "idle", label: "", brief: "", line: "", next: "" }
  }

  // The requests the harness opened, by id: the events that opened them are
  // its, whoever the request names as its requester.
  function noted(events) {
    const notes = {}
    for (const event of events)
      if (Requests.byHarness(event))
        notes[event.request_id] = true
    return notes
  }

  // The names of the tools a model event asks to call: an Anthropic message's
  // tool uses, an OpenAI message's tool calls, a Responses output's function
  // calls, or a command model's call; code mode's script is "code".
  function calls(body) {
    if (body === null || typeof body !== "object")
      return []
    const names = body.type === "call" ? [body.name]
      : Array.isArray(body.content) ? body.content.filter(part => part.type === "tool_use").map(part => part.name)
      : Array.isArray(body.tool_calls) ? body.tool_calls.map(call => call.function ? call.function.name : "")
      : Array.isArray(body.output) ? body.output.filter(part => part.type === "function_call").map(part => part.name)
      : []
    return names.filter(name => !!name).map(name => name === "__omunculus_execute" ? "code" : name)
  }

  // What a request asks, as {from, text, fine, origins, note}, each question
  // once: a reason an origin's question holds gives way to that question,
  // and an origin's question the text shown already holds is left out. A
  // request the harness opened, among `notes`, asks what it passes on, in
  // the words of whoever asked it, its own sentence the fine print; passing
  // on nothing, it is a note, its reason no one's words.
  function asking(request, notes) {
    const passed = notes[request.id] ? Requests.passedOn(request) : []
    if (passed.length > 0)
      return { from: Requests.label(passed[0].requester), text: passed.map(origin => origin.reason).join("\n\n"),
        fine: request.reason || "", origins: [], note: false }
    const plain = value => String(value || "").replace(/\s+/g, " ").trim().toLowerCase()
    const origins = Object.keys(request.origins || {}).map(part => ({ part: part, reason: request.origins[part].reason || "" }))
    const text = origins.map(origin => origin.reason)
      .filter(reason => plain(reason).includes(plain(request.reason)))
      .reduce((longest, reason) => reason.length > longest.length ? reason : longest, request.reason || "")
    return { from: notes[request.id] ? "note" : Requests.label(request.requester), text: text, fine: "",
      origins: origins.filter(origin => !plain(text).includes(plain(origin.reason))), note: !!notes[request.id] }
  }

  // A text on one line, without its Markdown marks, cut short when long.
  function oneLine(value) {
    const line = String(value || "").replace(/^\s*(?:[#>|-]+|\d+\.)\s*/gm, "").replace(/[*`|]/g, "").replace(/\s+/g, " ").trim()
    return line.length > 140 ? line.slice(0, 137) + "..." : line
  }

  // The message text a model event carries: a plain string, an OpenAI or
  // Anthropic message, a Responses output, or a command model's text turn; a
  // tool call alone has none.
  function text(body) {
    if (typeof body === "string")
      return body
    if (body === null || typeof body !== "object" || body.type === "call")
      return ""
    for (const key of ["content", "output"])
      if (typeof body[key] === "string")
        return body[key]
    for (const key of ["content", "output"])
      if (Array.isArray(body[key]))
        return body[key].map(part => typeof part.text === "string" ? part.text : text(part)).filter(part => part !== "").join("\n")
    return ""
  }

  // When something happened: the time today, the day before.
  function when(at) {
    const date = new Date(at)
    if (isNaN(date))
      return ""
    return date.toDateString() === new Date().toDateString() ? Qt.formatTime(date, "HH:mm") : Qt.formatDate(date, "d MMM")
  }

  FileView {
    id: seenFile
    path: Quickshell.statePath("seen.json")
    printErrors: false
    onLoaded: {
      try {
        root.seen = JSON.parse(text())
      } catch (e) {}
    }
  }

  Http {
    id: http
    onRefused: reason => root.tell(reason, true)
  }
}
