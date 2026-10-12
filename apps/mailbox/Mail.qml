pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "gui/Requests.js" as Requests

// Mail is every project of the server as the mailbox sees it. A thread is a
// conversation with one agent of depth 0: what you write goes to that agent,
// and what it says comes back. Its questions and approvals for you, the
// requests whose arbiter you are, show in the thread too. Every read and
// command goes to a project's local socket through curl.
Singleton {
  id: root

  // The socket the mailbox was opened on; it lists every project.
  readonly property string socket: Quickshell.env("OMUNCULUS_MAILBOX_SOCKET")

  property bool connected: false
  // You, as the server knows you: {issuer, subject}.
  property var me: null
  // Every project, as {id, socket, agents}: the agents of depth 0 a thread
  // can be with.
  property var projects: []
  // "project/conversation" -> its thread: {key, project, id, agent, subject,
  // working, waiting, at, heard, snippet, entries}.
  property var threads: ({})
  // Newest first.
  readonly property var all: Object.values(threads).sort((a, b) => b.at.localeCompare(a.at))
  // "all", "waiting" (a decision of yours) or "working" (a run open).
  property string folder: "all"
  // A project id, or "" for every project.
  property string project: ""
  readonly property var shown: all.filter(thread => (project === "" || thread.project === project)
    && (folder === "all" || (folder === "waiting" ? thread.waiting.length > 0 : thread.working)))
  property string selected: ""
  readonly property var thread: threads[selected] || null
  property bool composing: false

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
      tell("OMUNCULUS_MAILBOX_SOCKET is not set; start through apps/mailbox/run", true)
    else
      sweep()
  }

  Timer { interval: 2500; repeat: true; running: root.socket !== ""; onTriggered: root.sweep() }

  function tell(text, isError) {
    message = text
    messageIsError = isError
  }

  function isUnread(thread) {
    return thread.heard !== "" && (seen[thread.key] || "") < thread.heard
  }

  function projectOf(id) {
    return projects.find(item => item.id === id) || null
  }

  function open(key) {
    selected = key
    composing = false
    markSeen(key)
  }

  function close() {
    selected = ""
    composing = false
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
    composing = true
    selected = ""
  }

  // A new thread: a conversation in `project` and your first message to `agent` there.
  function send(project, agent, text) {
    const value = text.trim()
    const place = projectOf(project)
    if (value === "" || !place || agent === "")
      return
    call(place.socket, "POST", "/v1/projects/" + project + "/conversations", {}, true, data => {
      call(place.socket, "POST", "/v1/projects/" + project + "/conversations/" + data.id + "/messages",
        { message: value, agent: agent }, true, () => {
          composing = false
          selected = project + "/" + data.id
          tell("sent to " + agent, false)
          sweep()
        })
    })
  }

  // Your next message in a thread, to its agent.
  function reply(key, text) {
    const thread = threads[key]
    const value = text.trim()
    if (!thread || value === "")
      return
    call(projectOf(thread.project).socket, "POST", "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/messages",
      { message: value, agent: thread.agent }, true, () => {
        tell("sent to " + thread.agent, false)
        sweep()
      })
  }

  // Answers a request of a thread: an option it offers, text, or both.
  function decide(key, requestId, option, body) {
    const thread = threads[key]
    if (!thread || (!option && body.trim() === ""))
      return
    call(projectOf(thread.project).socket, "POST",
      "/v1/projects/" + thread.project + "/conversations/" + thread.id + "/requests/" + requestId + "/reply",
      Requests.answer(option, body.trim()), true, () => {
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
    call(socket, "GET", "/v1/identity", null, false, identity => {
      me = identity
      call(socket, "GET", "/v1/projects", null, false, data => {
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
          call(place.socket, "GET", "/v1/projects/" + place.id + "/conversations", null, false, list => {
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
      call(item.socket, "POST", "/v1/cli", { argv: ["config"] }, false, data => {
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
    call(place.socket, "GET", base + "/snapshot", null, false, snapshot => {
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
    call(on, "GET", base + "/events" + (cursor ? "?after=" + cursor : ""), null, false, data => {
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
    if (primed && thread.heard !== "" && (!before || before.heard < thread.heard) && selected !== key)
      announce(thread)
  }

  function announce(thread) {
    notifier.command = ["notify-send", "-a", "omunculus",
      thread.waiting.length > 0 ? thread.agent + " waits for you" : thread.agent + " · " + thread.subject, thread.snippet]
    notifier.startDetached()
  }
  Process { id: notifier }

  // Whether a participant is you.
  function isMe(participant) {
    return !!participant && !!me && Requests.human(participant) && participant.issuer === me.issuer && participant.subject === me.subject
  }

  // The thread a conversation's snapshot and events make. Its entries, in
  // order: each message you wrote; each run of an agent of depth 0, as what it
  // said; and each request whose arbiter is you.
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
        entries.push({ kind: "you", key: event.cursor, from: "you", to: body.agent || agent, text: body.message || "", at: event.at, open: false })
      } else if (event.type === "reply" && event.request_id) {
        replies[event.request_id] = { option: body.option || "", body: body.body || "" }
      } else if (rootRuns[event.run_id] && (event.type === "model" || event.type === "comment")) {
        const words = (event.type === "model" ? text(body) : String(body.body || "")).trim()
        if (words === "")
          continue
        const run = rootRuns[event.run_id]
        agent = agent || run.agent
        if (spoken[run.id] === undefined) {
          spoken[run.id] = entries.length
          entries.push({ kind: "agent", key: run.id, from: run.agent, to: "you", text: words, at: event.at, open: run.status === "open" })
        } else {
          entries[spoken[run.id]].text += "\n\n" + words
        }
      }
    }
    const asked = snapshot.requests.filter(request => isMe(request.arbiter))
    for (const request of asked)
      entries.push({
        kind: "request", key: request.id, from: Requests.label(request.requester), to: "you",
        text: request.reason || "", at: request.created_at, open: Requests.pending(request),
        options: Object.keys(request.options || {}),
        origins: Object.keys(request.origins || {}).map(part => ({ part: part, reason: request.origins[part].reason || "" })),
        answer: replies[request.id] || null
      })
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
      at: latest ? latest.at : snapshot.conversation.created_at,
      heard: theirs.length > 0 ? theirs[theirs.length - 1].at : "",
      snippet: latest ? oneLine((latest.kind === "you" ? "you: " : "") + latest.text) : "",
      entries: entries
    }
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

  // Text as Markdown should show it, with each line break kept.
  function markdown(value) {
    return String(value || "").replace(/([^\n])\n(?!\n)/g, "$1  \n")
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

  function key() {
    let value = ""
    for (let i = 0; i < 32; i++)
      value += Math.floor(Math.random() * 16).toString(16)
    return value
  }

  // One HTTP request through curl on the socket `on`; `done` gets the decoded
  // JSON of a 2xx answer, and `failed`, when given, takes any other outcome
  // instead of the status line.
  function call(on, method, path, body, idempotent, done, failed) {
    const args = ["curl", "-sS", "--unix-socket", on, "-X", method, "-H", "accept: application/json"]
    if (body !== null)
      args.push("-H", "content-type: application/json", "--data-binary", JSON.stringify(body))
    if (idempotent)
      args.push("-H", "Idempotency-Key: " + key())
    args.push("-w", "\n%{http_code}", "http://localhost" + path)
    httpCall.createObject(root, { command: args, done: done, failed: failed || null })
  }
  Component {
    id: httpCall
    Process {
      id: request
      property var done: null
      property var failed: null
      running: true
      stdout: StdioCollector {
        onStreamFinished: {
          const split = text.lastIndexOf("\n")
          const status = parseInt(text.slice(split + 1))
          const payload = text.slice(0, split)
          if (status >= 200 && status < 300) {
            request.done(payload === "" ? {} : JSON.parse(payload))
          } else {
            let reason = "the server does not answer on " + request.command[3]
            try {
              const error = JSON.parse(payload)
              reason = error.message || error.error
            } catch (e) {}
            if (request.failed)
              request.failed(reason)
            else
              root.tell(reason, true)
          }
          Qt.callLater(() => request.destroy())
        }
      }
    }
  }
}
