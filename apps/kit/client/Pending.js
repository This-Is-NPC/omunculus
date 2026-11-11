.pragma library
.import "Requests.js" as Requests
.import "Questions.js" as Questions
.import "Progress.js" as Progress

// What the chat and the pending queue say about requests and works, derived
// from the requests and the progress and never stored. Times are in seconds.

// The three kinds of item the queue holds, by Requests.kind: its word and icon.
const kinds = {
  "needs-you": { word: "QUESTION", icon: "help" },
  decision: { word: "DECISION", icon: "diamond" },
  permission: { word: "PERMISSION", icon: "shield" }
};

// What a request asks, by its shape, whoever decides it: "permission" when a
// decision grants, "decision" when it offers options, "needs-you" for a free
// answer.
function shape(request) {
  return Requests.granted(request) !== null ? "permission" : Requests.choices(request).length > 0 ? "decision" : "needs-you";
}

// The requests waiting on you, oldest first, none of which another request
// gathers from below: one question climbing is one item, at its top.
function queue(requests) {
  const hidden = Requests.contained(requests);
  return requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter) && !hidden.has(request.id))
    .map((request, at) => ({ request: request, at: at }))
    .sort((a, b) => String(a.request.created_at || "").localeCompare(String(b.request.created_at || "")) || a.at - b.at)
    .map(each => each.request);
}

// The first line of a text with words, on one line.
function headline(text) {
  const line = String(text || "").split("\n").find(each => each.trim() !== "");
  return line ? line.replace(/\s+/g, " ").trim() : "";
}

// What follows the headline, as it was written; "" when nothing does.
function rest(text) {
  const lines = String(text || "").split("\n");
  const at = lines.findIndex(each => each.trim() !== "");
  return at < 0 ? "" : lines.slice(at + 1).join("\n").trim();
}

// A headline split after its first sentence: {first, more}, `more` being "" for
// a headline that is one sentence.
function sentence(line) {
  const found = /^(.+?[.?!])\s+(\S.*)$/.exec(line);
  return found ? { first: found[1], more: found[2] } : { first: line, more: "" };
}

function capital(text) { return text.charAt(0).toUpperCase() + text.slice(1); }

function lower(text) { return text.charAt(0).toLowerCase() + text.slice(1); }

// "sales'" and "seller's".
function possessive(name) { return name + (name.endsWith("s") ? "'" : "'s"); }

// "a", "a and b", "a, b and c".
function names(list) {
  return list.length < 2 ? list.join("") : list.slice(0, -1).join(", ") + " and " + list[list.length - 1];
}

// The work a request climbed from, among the progress nodes `flat`: the
// deepest of the works it climbed through; null when none is known.
function nodeOf(request, flat) {
  const known = Requests.works(request).map(id => flat.find(node => node.work === id)).filter(node => node);
  return known.reduce((deepest, node) => !deepest || node.level > deepest.level ? node : deepest, null);
}

// The agents from the front desk down to the asker, as the hierarchy reads
// "front desk > seller > surgeon": the agents of the works the question
// climbed from, else the route it was passed on along.
function path(request, input) {
  const flat = input.flat || [];
  let agents = [];
  for (let at = nodeOf(request, flat); at; at = flat.find(each => each.work === at.parent))
    agents.unshift(at.agent);
  if (agents.length === 0)
    agents = Requests.route(request, input.noted && input.noted[request.id]).reverse();
  if (input.front && agents[0] !== input.front)
    agents.unshift(input.front);
  return agents.filter((name, at) => name && name !== agents[at - 1]);
}

// How a pending item reads: {id, kind, word, icon, asker, audience, path,
// work, title, body, unblocks, grants, since, asks}. `input`: {flat (progress
// nodes), front (the agent the person talks with), noted (request id -> true
// for one the harness passed on), folder (the root of the work's workspace),
// text (the question as its readers see it)}.
function describe(request, input) {
  const kind = shape(request);
  const look = kinds[kind];
  const asker = Requests.asker(request);
  const node = nodeOf(request, input.flat || []);
  const work = node ? node.title : "";
  const route = path(request, input);
  const form = kind === "needs-you" ? Questions.parse(input.text) : null;
  const wanted = Requests.granted(request);
  const unlocks = wanted ? Requests.unlocks(wanted, input.folder) : "";
  const above = route.slice(0, -1);
  const lead = wanted || form ? null : sentence(headline(input.text));
  const unblocks = [asker + " resumes " + (work !== "" ? work : "its work")]
    .concat(above.length > 0 ? [names(above) + (above.length > 1 ? " are" : " is") + " waiting for it"] : []).join(" · ");
  return {
    id: request.id, kind: kind, word: look.word, icon: look.icon,
    asker: asker, audience: Requests.audience(request), path: route, work: work,
    title: wanted ? capital(asker) + " asks to " + unlocks : form ? capital(asker) + " asks " + form.items.length + " questions" : lead.first,
    body: lead ? [lead.more, rest(input.text)].filter(part => part !== "").join("\n\n") : "",
    unblocks: unblocks,
    grants: wanted && Object.keys(request.options || {}).includes("grant") ? unlocks + " · this work only" : unlocks,
    since: request.created_at || "",
    asks: form ? form.items.length : 1
  };
}

// A request's options split as its action group shows them: the ones given
// once, the no or cancel, and, for a permission, the wider scopes behind
// "Always…". `primary` is the one given once that is recommended, the card's
// filled button: a grant, an approval or an acceptance; "" when none is.
function actions(options, permission) {
  const once = Requests.once(options, permission);
  return { once: once, primary: once.find(option => ["grant", "approve", "accept"].includes(option)) || "", denies: options.filter(Requests.guarded), always: Requests.always(options, permission) };
}

// What you did to a request, as one line of the chat: {icon, word, sentence}.
// `reply` is {option, body}; `input`: {text (the question as its readers see
// it), flat, folder}.
function resolved(request, reply, input) {
  const asker = Requests.asker(request);
  const node = nodeOf(request, input.flat || []);
  const where = node && node.title ? " (" + node.title + ")" : "";
  const option = reply.option || "";
  const wanted = Requests.granted(request);
  if (wanted) {
    const unlocks = Requests.unlocks(wanted, input.folder);
    if (Requests.guarded(option))
      return { icon: "close", word: "DENIED", sentence: "You denied " + asker + " permission to " + unlocks + where };
    const scope = option === "grant" || option === "" ? "" : " · " + Requests.optionLabel(option, { who: asker, folder: input.folder }).toLowerCase();
    return { icon: "shield", word: "GRANTED", sentence: "You granted " + asker + " permission to " + unlocks + scope + where };
  }
  if (option === "adjust")
    return { icon: "diamond", word: "ASKED", sentence: "You asked " + asker + " to adjust" + where };
  if (option)
    return { icon: "diamond", word: "CHOSE", sentence: "You chose " + Requests.optionText(option).toLowerCase() + " on " + possessive(asker) + " decision" + where };
  const form = Questions.parse(input.text);
  const count = form ? form.items.length : 1;
  return { icon: "help", word: "ANSWERED", sentence: "You answered " + possessive(asker) + " " + (count === 1 ? "question" : count + " questions") + where };
}

// A work's state in the words of the tree: WORKING, WAITING FOR SURGEON,
// WAITING FOR YOU, DONE, ...
function stateWord(node) {
  if (node.state === "needs-you") return "WAITING FOR YOU";
  if (node.state === "waiting") return "WAITING" + (node.waitingOn ? " FOR " + node.waitingOn.toUpperCase() : "");
  return Progress.word(node.state).toUpperCase();
}

// A work as its card in the chat reads: {work, title, state, word, now,
// waits, stage, steps, round, elapsed}. `now` is who works for it at the
// moment, {agent, doing}, or null; `waits` who it waits for, as a sentence,
// or ""; `stage` {at, count, name} its place in the workflow, or null. `at`
// is the clock in seconds.
function workCard(node, at) {
  const under = node.state === "working" ? [node] : Progress.underway(node);
  const worker = under.length > 0 ? under[under.length - 1] : null;
  const current = node.steps.findIndex(step => step.status === "current");
  const done = node.steps.filter(step => step.status === "done").length;
  return {
    work: node.work, title: node.title, state: node.state, word: stateWord(node),
    now: worker ? { agent: worker.agent, doing: lower(Progress.lively(worker.doing, worker.since, at)) } : null,
    waits: node.state === "waiting" && node.waitingOn ? node.agent + " is waiting for " + node.waitingOn : "",
    stage: node.steps.length === 0 ? null : { at: current >= 0 ? current + 1 : done, count: node.steps.length, name: current >= 0 ? node.steps[current].name : "" },
    steps: node.steps, round: node.round,
    elapsed: Progress.span(Progress.closed(node.state) ? node.own.seconds : Math.max(0, at - node.created))
  };
}
