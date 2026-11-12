.pragma library
.import "Requests.js" as Requests

// The mailbox's mapping from a conversation to e-mail. A thread is one
// conversation of one project, with the agent of depth 0 the person first
// wrote to; its e-mails are what the person wrote, what that agent
// explicitly addressed to them (its comments on the root work and the files it
// attached) and every question addressed to them, from its own requester. Everything here is pure: the window feeds it snapshots and events.

const labels = { progress: "In progress", stuck: "Stuck", cancelled: "Cancelled" };

// An agent's display name: its name, capitalised, words apart.
function capital(name) {
  const words = String(name || "").replace(/[-_]+/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

// An agent as a mail address book lists it: "Front-desk <front-desk@agency>".
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

// Every agent a thread can be with, across `projects` ([{id, agents,
// defaultAgent, canWrite}]); a project the person cannot write in gives none.
// Ordered for an address book: the project `first`, its default agent leading
// it, then the rest of that project, then the other projects in their order.
function recipients(projects, first) {
  const ordered = projects.filter(place => place.canWrite !== false)
    .map((place, index) => ({ place: place, rank: place.id === first ? -1 : index }))
    .sort((a, b) => a.rank - b.rank);
  return ordered.reduce((all, entry) => {
    const agents = entry.place.agents.slice().sort((a, b) => (b === entry.place.defaultAgent) - (a === entry.place.defaultAgent));
    return all.concat(agents.map(agent => person(agent, entry.place.id)));
  }, []);
}

// Whether a project's capabilities (GET /capabilities) let the person start a
// conversation and write in it.
function canWrite(capabilities) {
  return ["conversation.create", "conversation.send"].every(name => (capabilities || []).includes(name));
}

// The recipients whose name or address holds `query`, case aside.
function suggest(list, query) {
  const text = String(query || "").trim().toLowerCase();
  return list.filter(item => text === "" || item.name.toLowerCase().includes(text) || item.address.toLowerCase().includes(text));
}

// What the empty To field says: who a message goes to when it is left empty,
// the project's default agent as a person, or null for none.
function hint(fallback) {
  return fallback ? "to " + fallback.name + " if left empty" : "name or address";
}

// Where a message goes: {project, agent} for the account chosen; for none,
// the fallback's project and no agent, which the server routes to the
// project's default agent; null when there is neither.
function sendTarget(chosen, fallback) {
  if (chosen) return { project: chosen.project, agent: chosen.agent };
  return fallback ? { project: fallback.project, agent: "" } : null;
}

// The recipients to offer for `query`, none until something is typed: those
// whose name or address holds it, case aside, but the addresses in `taken`.
function complete(list, query, taken) {
  if (String(query || "").trim() === "") return [];
  return suggest(list, query).filter(item => !(taken || []).includes(item.address));
}

// Every account a thread is with: its agent first, then each other who wrote
// in it or whom you wrote to, once, as a person with an address.
function counterparts(thread) {
  const all = [thread.with];
  for (const message of thread.messages) {
    const other = message.mine ? message.to : message.from;
    if (other && other.address && !all.some(item => item.address === other.address)) all.push(other);
  }
  return all;
}

// Whether a thread has more than one counterpart, so Reply all differs from Reply.
function canReplyAll(thread) {
  return counterparts(thread).length > 1;
}

// Whom a reply to `message` of `thread` is prefilled to: its other party, or,
// for Reply all, every counterpart of the thread.
function replyRecipients(thread, message, all) {
  if (all) return counterparts(thread);
  const other = message ? (message.mine ? message.to : message.from) : null;
  return [other && other.address ? other : thread.with];
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

// A message quoted as mail does: {head: "On <when>, Front-desk wrote:", lines}, each
// line of its text behind "> " (no trimEnd: the QML engine lacks it). `when` is the date as the person reads it.
function quoted(message, when) {
  return {
    head: "On " + when + ", " + message.from.name + " wrote:",
    lines: String(message.text || "").split("\n").map(line => ("> " + line).replace(/\s+$/, ""))
  };
}

// What a request asks, in the thread agent's own words: its reason. The
// questions of its origins are other agents' text and are not shown. Only a
// request the harness opened (`noted`) that passes on questions has no reason
// of its own (its sentence says how it came to the person), so it asks what it
// passes on.
function asking(request, noted) {
  return Requests.question(request, noted);
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

// A request's requester as a person: an agent with its own address, any
// other account by its name.
function requester(request, projectId) {
  const who = request.requester;
  return who && who.agent ? person(who.agent, projectId)
    : { agent: "", project: projectId, name: Requests.label(who), address: "", text: Requests.label(who) };
}

// How a decision on a review reads once made.
const decided = { approve: "Approved", edit: "Edited", deny: "Denied" };

// What each answer to a review does, as the review's last line tells it;
// `who` is the one who acted, `text` what the action holds ("" for a tool or
// a grant, which edit approves with a note).
function outcome(who, text) {
  return "If you approve: " + who + " goes ahead as written. Edit " + (text !== "" ? "changes its text" : "approves with your note")
    + ". Deny tells " + who + " no.";
}

// The reviews waiting on the person in a conversation, which the Pending
// folder lists and mail never holds: {key, project, conversation, request,
// from (the requester as a person), summary (a sentence, the subject), args
// (the {name, value} lines of a tool's arguments), text (what the action
// holds, "" for a tool or a grant), outcome, reason, at}.
function reviews(projectId, id, snapshot, me) {
  return snapshot.requests.filter(request => Requests.review(request) && Requests.pending(request) && Requests.forYou(request, me))
    .map(request => {
      const from = requester(request, projectId);
      const text = Requests.editable(request);
      return {
        key: projectId + "/" + id + "/" + request.id, project: projectId, conversation: id, request: request.id,
        from: from, summary: sentence(request.interception.summary), args: request.interception.args || [],
        text: text, outcome: outcome(from.name, text),
        reason: String(request.reason || ""), at: request.created_at
      };
    });
}

// A summary as a subject: its first letter in capitals.
function sentence(text) {
  const value = String(text || "");
  return value.charAt(0).toUpperCase() + value.slice(1);
}

// The record of an answer to a review, as the mail you sent: "Approved: <the
// sentence>", then the words that went with an edit or a denial.
function answered(request, reply) {
  const option = (reply.body || {}).option || "";
  const words = String((reply.body || {}).body || "");
  const more = words !== "" && words !== option ? "\n\n" + words : "";
  return (decided[option] || "Answered") + ": " + sentence(request.interception.summary) + more;
}

// The thread a conversation's snapshot and events make:
//   key, project, id, agent, with: the agent as a person, subject, label,
//   messages (oldest first), pending: the ids of the requests the person has
//   to answer, oldest first, reviews: the reviews waiting on them, at: the last message's time, heard: the last
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
  const attached = [];
  const rootWorks = {};
  for (const work of snapshot.works) if (!work.parent_id) rootWorks[work.id] = true;
  const replies = {};
  for (const event of events) {
    const body = event.body || {};
    if (event.type === "prompt" && event.actor && event.actor.kind === "human") {
      if (body.agent && body.agent !== agent) continue;
      messages.push({ key: event.cursor, mine: true, from: you, to: agentPerson, text: body.message || "", at: event.at, files: body.attachments || [], request: "", pending: false, open: false });
    } else if (event.type === "reply" && event.request_id && Requests.isMe(event.actor, me)) {
      replies[event.request_id] = event;
    } else if (rootRuns[event.run_id] && event.type === "comment" && rootWorks[event.work_id] && String(body.body || "").trim() !== "") {
      // Only what the agent explicitly addresses to the person is an e-mail:
      // a comment on the conversation's root work. Its model text is its own
      // narration, console only.
      const run = rootRuns[event.run_id];
      const words = String(body.body).trim();
      if (spoken[run.id] === undefined) {
        spoken[run.id] = messages.length;
        messages.push({ key: run.id, mine: false, from: agentPerson, to: you, text: words, at: event.at, files: [], request: "", pending: false, open: run.status === "open" });
      } else {
        const message = messages[spoken[run.id]];
        message.text = message.text + "\n\n" + words;
      }
    } else if (rootRuns[event.run_id] && event.type === "attach" && Array.isArray(body.attachments) && body.attachments.length > 0) {
      attached.push(event);
    }
  }
  const notes = noted(events);
  // What reaches the person: every question whose arbiter they are, from its
  // own requester; whoever else a question was written for stays off their mail.
  const asked = snapshot.requests.filter(request => Requests.forYou(request, me) && !Requests.review(request)
    && !(notes[request.id] && Requests.passedOn(request).length === 0));
  const held = reviews(projectId, id, snapshot, me);
  const waiting = asked.filter(request => Requests.pending(request)).map(request => request.id);
  for (const request of asked) {
    const sender = requester(request, projectId);
    messages.push({ key: request.id, mine: false, from: sender, to: you, text: asking(request, notes[request.id]), at: request.created_at, files: [], request: request.id, pending: Requests.pending(request), open: false });
    const reply = replies[request.id];
    if (reply) messages.push({ key: reply.cursor, mine: true, from: you, to: sender, text: String((reply.body || {}).body || ""), at: reply.at, files: [], request: request.id, pending: false, open: false });
  }
  // An answer you gave to a review is mail you sent to its requester.
  for (const request of snapshot.requests.filter(each => Requests.review(each) && Requests.isMe(each.arbiter, me) && replies[each.id])) {
    const reply = replies[request.id];
    messages.push({ key: reply.cursor, mine: true, from: you, to: requester(request, projectId), text: answered(request, reply), at: reply.at, files: [], request: request.id, pending: false, open: false });
  }
  // A file belongs to the e-mail of its own run: the request that run raised
  // when it raised one, else its comments, else an e-mail of its own.
  for (const event of attached) {
    const run = rootRuns[event.run_id];
    const own = messages.find(message => !message.mine && message.request !== ""
      && asked.some(request => request.id === message.request && request.run_id === run.id));
    const target = own || messages[spoken[run.id]];
    if (target) target.files = target.files.concat(event.body.attachments);
    else {
      spoken[run.id] = messages.length;
      messages.push({ key: run.id, mine: false, from: agentPerson, to: you, text: "", at: event.at, files: event.body.attachments.slice(), request: "", pending: false, open: false });
    }
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
    label: label(snapshot, events, waiting.concat(held.map(review => review.request))),
    messages: messages, pending: waiting, reviews: held,
    at: latest ? latest.at : snapshot.conversation.created_at,
    heard: theirs.length > 0 ? theirs[theirs.length - 1].at : "",
    received: theirs.length, sent: mine,
    parties: parties(agentPerson.name, theirs, mine > 0, messages.length),
    snippet: latest ? oneLine(latest.text + (latest.files.length > 0 ? " [" + latest.files.map(file => file.name).join(", ") + "]" : "")) : ""
  };
}

// The names of everyone who wrote in a thread: its agent, then the others who
// did, each once in the order they first did, then "me", and how many messages
// it holds.
function parties(agent, theirs, wrote, count) {
  const names = [agent].concat(theirs.map(message => message.from.name)).filter((name, at, all) => all.indexOf(name) === at);
  return names.concat(wrote ? ["me"] : []).join(", ") + (count > 1 ? " (" + count + ")" : "");
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
function answer(text) {
  return { body: String(text).trim() };
}

// The reply body of a decision on a review: "approve", "edit" (the words
// replace the held text) or "deny" (the words are its reason, optional).
function decision(option, text) {
  return Requests.answer(option, String(text).trim(), []);
}

// A forward of a message as the compose window starts it: {subject, body}.
function forward(thread, message) {
  const head = "---------- Forwarded message ----------\nFrom: " + message.from.name + (message.from.address ? " <" + message.from.address + ">" : "")
    + "\nSubject: " + thread.subject + "\n\n";
  return { subject: fwd(thread.subject), body: "\n\n" + head + message.text };
}

// Whether a review holds what the search asks for.
function reviewMatches(review, query) {
  const text = String(query || "").trim().toLowerCase();
  return text === "" || [review.summary, review.text, review.reason, review.from.address, review.from.name].some(word => String(word).toLowerCase().includes(text));
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
  return folder === "sent" ? thread.sent > 0 : folder === "inbox" ? thread.received > 0 : false; // "pending" holds reviews, not threads
}

// Whether a thread has mail from its agent that `seen` (thread key to the time
// of the last one read) does not hold.
function isUnread(thread, seen) {
  return thread.heard !== "" && (seen[thread.key] || "") < thread.heard;
}

// What the folded list rail shows: how many e-mails the folder holds and how
// many of them are unread, as {total, unread}.
function railCount(threads, seen) {
  return { total: threads.length, unread: threads.filter(thread => isUnread(thread, seen)).length };
}
