pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "gui/Requests.js" as Requests

// Mail is the project as the mailbox sees it: each conversation is one mail,
// what you wrote in it and the answers its root agent gave once the agents had
// finished. While they work, the mail says only that; what they do on the way
// stays out. A request whose arbiter is a person is the one thing that arrives
// before the end: it waits in the inbox for your decision. Every read and
// command goes to the server's local socket through curl.
Singleton {
  id: root

  readonly property string socket: Quickshell.env("OMUNCULUS_MAILBOX_SOCKET")
  readonly property string project: Quickshell.env("OMUNCULUS_MAILBOX_PROJECT")
  readonly property string base: "/v1/projects/" + project

  property bool connected: false
  // Conversation id -> its mail: {id, subject, state ("working", "decide" or
  // "done"), at, delivered, snippet, letters, decisions}.
  property var mails: ({})
  // Newest first.
  readonly property var all: Object.values(mails).sort((a, b) => b.at.localeCompare(a.at))
  // The inbox holds what was delivered: answers, and decisions to make.
  readonly property var inbox: all.filter(mail => mail.state !== "working")
  property string folder: "inbox"
  readonly property var shown: folder === "inbox" ? inbox : all
  property string selected: ""
  readonly property var mail: mails[selected] || null
  property bool composing: false

  // Conversation id -> the delivery last opened; kept across sessions.
  property var seen: ({})
  readonly property int unread: inbox.filter(mail => isUnread(mail)).length
  readonly property int deciding: all.filter(mail => mail.state === "decide").length
  readonly property int working: all.filter(mail => mail.state === "working").length

  property string message: ""
  property bool messageIsError: false

  // Conversation id -> {cursor, events, snapshot}: what the mail is built from.
  property var cache: ({})
  // A sweep reads the conversations and the snapshots that changed; one at a time.
  property bool sweeping: false
  // After the first sweep, a new delivery is announced on the desktop.
  property bool primed: false

  Component.onCompleted: {
    if (socket === "" || project === "")
      tell("OMUNCULUS_MAILBOX_SOCKET and OMUNCULUS_MAILBOX_PROJECT are not set; start through apps/mailbox/run", true)
    else
      sweep()
  }

  Timer { interval: 2500; repeat: true; running: root.socket !== ""; onTriggered: root.sweep() }

  function tell(text, isError) {
    message = text
    messageIsError = isError
  }

  function isUnread(mail) {
    return mail.state !== "working" && seen[mail.id] !== mail.delivered
  }

  function open(id) {
    selected = id
    composing = false
    const mail = mails[id]
    if (mail && mail.state !== "working" && seen[id] !== mail.delivered) {
      seen = Object.assign({}, seen, { [id]: mail.delivered })
      seenFile.setText(JSON.stringify(seen))
    }
  }

  // The selected mail's delivery is read as it arrives while it is open.
  onMailsChanged: {
    const open = mails[selected]
    if (open && open.state !== "working" && seen[selected] !== open.delivered)
      root.open(selected)
  }

  function compose() {
    composing = true
    selected = ""
  }

  // A new mail: a conversation of its own, and your message in it.
  function send(text) {
    const value = text.trim()
    if (value === "")
      return
    call("POST", base + "/conversations", {}, true, data => {
      call("POST", base + "/conversations/" + data.id + "/messages", { message: value }, true, () => {
        composing = false
        folder = "sent"
        selected = data.id
        tell("sent", false)
        sweep()
      })
    })
  }

  // Writing again in a mail sends it back to its agents.
  function reply(id, text) {
    const value = text.trim()
    if (value === "")
      return
    call("POST", base + "/conversations/" + id + "/messages", { message: value }, true, () => {
      tell("sent", false)
      sweep()
    })
  }

  // Answers a request: an option it offers, text, or both.
  function decide(id, requestId, option, body) {
    if (!option && body.trim() === "")
      return
    call("POST", base + "/conversations/" + id + "/requests/" + requestId + "/reply",
      Requests.answer(option, body.trim()), true, () => {
        tell(option ? "answered " + option : "answered", false)
        sweep()
      })
  }

  function sweep() {
    if (sweeping)
      return
    sweeping = true
    call("GET", base + "/conversations", null, false, data => {
      connected = true
      const ids = data.items.map(item => item.id)
      for (const id of Object.keys(mails))
        if (!ids.includes(id))
          forget(id)
      next(ids)
    }, () => {
      connected = false
      sweeping = false
    })
  }

  function forget(id) {
    const left = Object.assign({}, mails)
    delete left[id]
    mails = left
    delete cache[id]
  }

  // Reads each conversation's snapshot in turn, and its new events when it changed.
  function next(ids) {
    if (ids.length === 0) {
      sweeping = false
      primed = true
      return
    }
    const id = ids[0]
    const rest = () => next(ids.slice(1))
    call("GET", base + "/conversations/" + id + "/snapshot", null, false, snapshot => {
      const known = cache[id] || { cursor: "", events: [], snapshot: null }
      if (known.snapshot && known.snapshot.cursor === snapshot.cursor)
        return rest()
      events(id, known.cursor, known.events, (cursor, all) => {
        cache[id] = { cursor: cursor, events: all, snapshot: snapshot }
        update(id, build(id, snapshot, all))
        rest()
      }, rest)
    }, rest)
  }

  // Every event after `cursor`, a page of up to 500 at a time.
  function events(id, cursor, read, done, failed) {
    call("GET", base + "/conversations/" + id + "/events" + (cursor ? "?after=" + cursor : ""), null, false, data => {
      const all = read.concat(data.events)
      const last = data.events.length > 0 ? data.events[data.events.length - 1].cursor : cursor
      if (data.events.length === 500)
        events(id, last, all, done, failed)
      else
        done(last, all)
    }, failed)
  }

  function update(id, mail) {
    const before = mails[id]
    mails = Object.assign({}, mails, { [id]: mail })
    if (primed && mail.state !== "working" && (!before || before.delivered !== mail.delivered) && selected !== id)
      announce(mail)
  }

  function announce(mail) {
    notifier.command = ["notify-send", "-a", "omunculus", mail.state === "decide" ? "Your decision is needed" : "Answered: " + mail.subject,
      mail.snippet]
    notifier.startDetached()
  }
  Process { id: notifier }

  // The mail a conversation's snapshot and events make.
  function build(id, snapshot, events) {
    const messages = snapshot.prompts.filter(prompt => prompt.kind === "message" && prompt.actor_issuer)
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
    const rootRuns = snapshot.runs.filter(run => String(run.depth) === "0")
    const said = {}
    const replies = {}
    for (const event of events) {
      if (event.type === "reply" && event.request_id)
        replies[event.request_id] = { option: (event.body || {}).option || "", body: (event.body || {}).body || "" }
      if (!rootRuns.some(run => run.id === event.run_id))
        continue
      const words = event.type === "model" ? text(event.body) : event.type === "comment" ? String((event.body || {}).body || "") : ""
      if (words.trim() !== "")
        (said[event.run_id] = said[event.run_id] || []).push(words.trim())
    }

    const busy = snapshot.runs.some(run => run.status === "open")
      || snapshot.works.some(work => work.state === "open" || work.state === "waiting")
    const asked = snapshot.requests.filter(request => Requests.human(request.arbiter))
    const pending = asked.filter(request => Requests.pending(request))

    // Each message you wrote and the answer to it: what the last root run
    // that finished before your next message said. The last one counts only
    // once nothing works any more.
    const letters = []
    messages.forEach((prompt, index) => {
      letters.push({ kind: "you", text: prompt.body, at: prompt.created_at })
      const until = index + 1 < messages.length ? messages[index + 1].created_at : null
      const closed = rootRuns.filter(run => run.finished_at && run.started_at >= prompt.created_at && (!until || run.started_at < until))
        .sort((a, b) => a.finished_at.localeCompare(b.finished_at))
      const last = index === messages.length - 1
      if (closed.length === 0 || (last && (busy || pending.length > 0)))
        return
      const spoken = closed.filter(run => said[run.id])
      const answer = spoken.length > 0 ? spoken[spoken.length - 1] : closed[closed.length - 1]
      letters.push({ kind: "answer", text: (said[answer.id] || []).join("\n\n"), at: answer.finished_at, who: answer.agent })
    })
    for (const request of asked.filter(request => !Requests.pending(request)))
      letters.push({ kind: "decided", text: request.reason, at: request.created_at, answer: replies[request.id] || null })
    letters.sort((a, b) => a.at.localeCompare(b.at))

    const decisions = pending.map(request => ({
      id: request.id,
      reason: request.reason,
      asker: Requests.label(request.requester),
      options: Object.keys(request.options || {}),
      origins: Object.keys(request.origins || {}).map(part => ({ part: part, reason: request.origins[part].reason })),
      at: request.created_at
    }))

    const answered = letters.length > 0 && letters[letters.length - 1].kind === "answer"
    const state = decisions.length > 0 ? "decide" : busy || !answered ? "working" : "done"
    const first = messages.length > 0 ? String(messages[0].body).trim().split("\n")[0] : ""
    const latest = letters.length > 0 ? letters[letters.length - 1] : null
    const delivered = state === "decide" ? decisions.map(item => item.id).join(",")
      : state === "done" ? latest.at : ""
    return {
      id: id,
      subject: first.length > 80 ? first.slice(0, 77) + "..." : first || "(no message)",
      state: state,
      at: [snapshot.conversation.created_at].concat(letters.map(item => item.at), decisions.map(item => item.at)).sort().pop(),
      delivered: delivered,
      snippet: oneLine(state === "decide" ? decisions[0].reason : state === "done" ? latest.text || "The agents finished without a word." : "Your agents are working on it."),
      letters: letters,
      decisions: decisions
    }
  }

  function oneLine(value) {
    const line = String(value || "").replace(/\s+/g, " ").trim()
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
    path: Quickshell.statePath("seen-" + root.project + ".json")
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

  // One HTTP request through curl; `done` gets the decoded JSON of a 2xx
  // answer, and `failed`, when given, takes any other outcome instead of the
  // status line.
  function call(method, path, body, idempotent, done, failed) {
    const args = ["curl", "-sS", "--unix-socket", socket, "-X", method, "-H", "accept: application/json"]
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
            let reason = "the server does not answer on " + root.socket
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
