.pragma library
.import "Requests.js" as Requests
.import "Model.js" as Model

// The mailbox's mapping from a conversation to e-mail. A thread is one
// conversation of one project, with the agent of depth 0 the person first
// wrote to; its e-mails are what the person wrote, what that agent said to
// them and the requests it addressed to them, never anything of another
// agent. Everything here is pure: the window feeds it snapshots and events.

const labels = { progress: "In progress", stuck: "Stuck", cancelled: "Cancelled" };

// An agent's display name: its name, capitalised, words apart.
function capital(name) {
  const words = String(name || "").replace(/[-_]+/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

// An agent as a mail address book lists it: "Sales <sales@agency>".
function person(agent, project) {
  const address = agent + "@" + project;
  return { agent: agent, project: project, name: capital(agent), address: address, text: capital(agent) + " <" + address + ">" };
}

// The agents of depth 0 a person may write to, from a config's roster.
function chat(roster) {
  return (roster || []).filter(agent => agent.depth === 0 && !agent.workflow_only).map(agent => agent.name);
}

// The agent a project's config declares as its default, when it may be written
// to; "" otherwise. `setup` is GET /config?whole=true.
function defaultAgent(setup) {
  const name = setup && typeof setup.default_agent === "string" ? setup.default_agent : "";
  return chat(setup && setup.agents).includes(name) ? name : "";
}

// Every agent a thread can be with, across `projects` ([{id, agents}]).
function recipients(projects) {
  return projects.reduce((all, place) => all.concat(place.agents.map(agent => person(agent, place.id))), []);
}

// The recipients whose name or address holds `query`, case aside.
function suggest(list, query) {
  const text = String(query || "").trim().toLowerCase();
  return list.filter(item => text === "" || item.name.toLowerCase().includes(text) || item.address.toLowerCase().includes(text));
}

function isMe(participant, me) {
  return !!participant && !!me && Requests.human(participant) && participant.issuer === me.issuer && participant.subject === me.subject;
}

// A text on one line, without its Markdown marks, cut short when long.
function oneLine(value) {
  const line = String(value || "").replace(/^\s*(?:[#>|-]+|\d+\.)\s*/gm, "").replace(/[*`|]/g, "").replace(/\s+/g, " ").trim();
  return line.length > 140 ? line.slice(0, 137) + "..." : line;
}

// A first message as subject and body: its first line is the subject, the rest
// the body; a single line, or a first line too long for one, is its own body.
function split(text) {
  const value = String(text || "").trim();
  const at = value.indexOf("\n");
  const first = (at < 0 ? value : value.slice(0, at)).trim();
  const rest = at < 0 ? "" : value.slice(at + 1).trim();
  if (first.length > 90 || rest === "") return { subject: first.length > 90 ? first.slice(0, 87) + "..." : first, body: value };
  return { subject: first, body: rest };
}

// A subject as an answer to it reads.
function re(subject) { return /^re:/i.test(subject) ? subject : "Re: " + subject; }

// A subject as a forward of it reads.
function fwd(subject) { return /^fwd?:/i.test(subject) ? subject : "Fwd: " + subject; }

// A text quoted as mail does, each line behind "> ".
function quote(text) {
  return String(text || "").split("\n").map(line => ("> " + line).trimEnd()).join("\n");
}

// What a request asks, each question once: its reason, or an origin's
// question that holds it; then each origin's question the text does not
// already hold. A request the harness opened (`noted`) asks what it passes on.
// The harness's own sentence on how it came to the person is left out.
function asking(request, noted) {
  const passed = noted ? Requests.passedOn(request) : [];
  if (passed.length > 0) return Requests.question(request, true);
  const plain = value => String(value || "").replace(/\s+/g, " ").trim().toLowerCase();
  const reasons = Object.keys(request.origins || {}).map(part => String(request.origins[part].reason || ""));
  const text = reasons.filter(reason => plain(reason).includes(plain(request.reason)))
    .reduce((longest, reason) => reason.length > longest.length ? reason : longest, String(request.reason || ""));
  return [text].concat(reasons.filter(reason => plain(reason) !== "" && !plain(text).includes(plain(reason)))).join("\n\n");
}

// The requests the harness opened, by id.
function noted(events) {
  const notes = {};
  for (const event of events) if (Requests.byHarness(event)) notes[event.request_id] = true;
  return notes;
}

// The agent a conversation is with: the one its first message names, else the
// first agent of depth 0 that ran.
function agentOf(snapshot, events) {
  const prompt = events.find(event => event.type === "prompt" && event.actor && event.actor.kind === "human" && event.body && event.body.agent);
  if (prompt) return prompt.body.agent;
  const run = snapshot.runs.filter(each => String(each.depth) === "0" && each.agent)
    .sort((a, b) => String(a.started_at || "").localeCompare(String(b.started_at || "")))[0];
  return run ? run.agent : "";
}

// The label of a conversation, as the person reads it: "progress" while a run
// is open or something waits on someone else; "" while the agency waits for
// the person, whose e-mail is unread, not labelled; "cancelled" once every
// root work is; "stuck" when nothing runs and the last run failed or a work
// is still open. `waiting` lists the requests the person must answer.
function label(snapshot, events, waiting) {
  if (snapshot.runs.some(run => run.status === "open")) return "progress";
  if (waiting.length > 0) return "";
  const roots = snapshot.works.filter(work => !work.parent_id);
  if (roots.length > 0 && roots.every(work => work.state === "cancelled")) return "cancelled";
  if (snapshot.requests.some(request => Requests.pending(request))
    || snapshot.works.some(work => work.state === "waiting" && work.waiting === "child")) return "progress";
  if (roots.some(work => work.state === "waiting" && work.waiting === "message")) return "";
  const ended = {};
  for (const event of events) if (event.type === "end-run" && event.run_id) ended[event.run_id] = event.body || {};
  const last = snapshot.runs.slice().sort((a, b) => String(a.finished_at || "").localeCompare(String(b.finished_at || ""))).pop();
  if (last && ended[last.id] && ended[last.id].error) return "stuck";
  return snapshot.works.some(work => work.state === "open" || work.state === "waiting") ? "stuck" : "";
}

// The thread a conversation's snapshot and events make:
//   key, project, id, agent, with: the agent as a person, subject, label,
//   messages (oldest first), pending: the ids of the requests the person has
//   to answer, oldest first, at: the last message's time, heard: the last
//   message from the agent's, "" for none, received, sent, parties, snippet.
// A message: {key, mine, from, to, text, at, files, request, pending, open}.
function build(projectId, id, snapshot, events, me) {
  const agent = agentOf(snapshot, events);
  const you = { name: "me", address: "", me: true };
  const agentPerson = person(agent, projectId);
  const rootRuns = {};
  for (const run of snapshot.runs) if (String(run.depth) === "0" && run.agent === agent) rootRuns[run.id] = run;
  const messages = [];
  const spoken = {};
  const replies = {};
  for (const event of events) {
    const body = event.body || {};
    if (event.type === "prompt" && event.actor && event.actor.kind === "human") {
      if (body.agent && body.agent !== agent) continue;
      messages.push({ key: event.cursor, mine: true, from: you, to: agentPerson, text: body.message || "", at: event.at, files: body.attachments || [], request: "", pending: false, open: false });
    } else if (event.type === "reply" && event.request_id && isMe(event.actor, me)) {
      replies[event.request_id] = event;
    } else if (rootRuns[event.run_id] && ["model", "comment", "attach"].includes(event.type)) {
      // A reply that calls a tool is the agent acting, its text narrating the
      // call to itself; only a reply that calls none speaks to the person.
      const words = (event.type === "model" ? (Model.calls(body).length > 0 ? "" : Model.text(body))
        : event.type === "comment" ? String(body.body || "") : String(body.note || "")).trim();
      const files = event.type === "attach" ? body.attachments || [] : [];
      if (words === "" && files.length === 0) continue;
      const run = rootRuns[event.run_id];
      if (spoken[run.id] === undefined) {
        spoken[run.id] = messages.length;
        messages.push({ key: run.id, mine: false, from: agentPerson, to: you, text: words, at: event.at, files: files, request: "", pending: false, open: run.status === "open" });
      } else {
        const message = messages[spoken[run.id]];
        message.text = [message.text, words].filter(part => part !== "").join("\n\n");
        message.files = message.files.concat(files);
      }
    }
  }
  const notes = noted(events);
  const asked = snapshot.requests.filter(request => isMe(request.arbiter, me)
    && !(notes[request.id] && Requests.passedOn(request).length === 0)
    && (!!notes[request.id] || (!!request.requester && request.requester.agent === agent)));
  const waiting = asked.filter(request => Requests.pending(request)).map(request => request.id);
  for (const request of asked) {
    messages.push({ key: request.id, mine: false, from: agentPerson, to: you, text: asking(request, notes[request.id]), at: request.created_at, files: [], request: request.id, pending: Requests.pending(request), open: false });
    const reply = replies[request.id];
    if (reply) messages.push({ key: reply.cursor, mine: true, from: you, to: agentPerson, text: String((reply.body || {}).body || ""), at: reply.at, files: [], request: request.id, pending: false, open: false });
  }
  messages.sort((a, b) => a.at.localeCompare(b.at));
  waiting.sort((a, b) => asked.find(r => r.id === a).created_at.localeCompare(asked.find(r => r.id === b).created_at));

  const first = messages.find(message => message.mine && message.request === "");
  const parts = first ? split(first.text) : { subject: "", body: "" };
  if (first) first.text = parts.body;
  const theirs = messages.filter(message => !message.mine);
  const latest = messages.length > 0 ? messages[messages.length - 1] : null;
  const mine = messages.length - theirs.length;
  return {
    key: projectId + "/" + id, project: projectId, id: id, agent: agent, with: agentPerson,
    subject: parts.subject || "(no subject)",
    label: label(snapshot, events, waiting),
    messages: messages, pending: waiting,
    at: latest ? latest.at : snapshot.conversation.created_at,
    heard: theirs.length > 0 ? theirs[theirs.length - 1].at : "",
    received: theirs.length, sent: mine,
    parties: agentPerson.name + (mine > 0 ? ", me" : "") + (messages.length > 1 ? " (" + messages.length + ")" : ""),
    snippet: latest ? oneLine(latest.text + (latest.files.length > 0 ? " [" + latest.files.map(file => file.name).join(", ") + "]" : "")) : ""
  };
}

// What a reply written while reading `key` of `thread` does: {request, quoted}.
// It answers the request of the message replied to when that is pending; else,
// while requests wait, the newest of them; with none waiting it is a message to
// the agent (`request` ""). `quoted` is the message it answers, the one the
// editor quotes, so what a reply answers is always in view.
function replyTarget(thread, key) {
  const message = thread.messages.find(each => each.key === key) || thread.messages[thread.messages.length - 1] || null;
  const own = message && message.pending ? message.request : "";
  const request = own || (thread.pending.length > 0 ? thread.pending[thread.pending.length - 1] : "");
  const quoted = request ? thread.messages.find(each => each.request === request && !each.mine) : message;
  return { request: request, quoted: quoted || null };
}

// The request reply body for an answer in words: text only, never an option.
function answer(text) { return { body: String(text).trim() }; }

// A forward of a message as the compose window starts it: {subject, body}.
function forward(thread, message) {
  const head = "---------- Forwarded message ----------\nFrom: " + message.from.name + (message.from.address ? " <" + message.from.address + ">" : "")
    + "\nSubject: " + thread.subject + "\n\n";
  return { subject: fwd(thread.subject), body: "\n\n" + head + message.text };
}

// Whether a thread holds what the search asks for, in its subject, agent,
// project, any message or the names of their files.
function matches(thread, query) {
  const text = String(query || "").trim().toLowerCase();
  if (text === "") return true;
  const words = [thread.subject, thread.agent, thread.project]
    .concat(thread.messages.map(message => message.text), thread.messages.reduce((names, message) => names.concat(message.files.map(file => file.name)), []));
  return words.some(word => String(word).toLowerCase().includes(text));
}

// Whether a thread shows in a folder. `archived` maps thread keys to when
// they were archived; a thread comes back to the inbox when it receives mail
// after that. "drafts" holds no threads.
function inFolder(thread, folder, archived) {
  const away = archived[thread.key] !== undefined && thread.at <= archived[thread.key];
  if (folder === "archive") return away;
  if (away) return false;
  return folder === "sent" ? thread.sent > 0 : folder === "inbox" ? thread.received > 0 : false;
}

// Whether a thread has mail from its agent that `seen` (thread key to the time
// of the last one read) does not hold.
function isUnread(thread, seen) {
  return thread.heard !== "" && (seen[thread.key] || "") < thread.heard;
}
