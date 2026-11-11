.pragma library
.import "Requests.js" as Requests
.import "Questions.js" as Questions
.import "Progress.js" as Progress

// What the chat and the pending queue say about requests and works, derived
// from the requests and the progress and never stored. Times are in seconds.

// The requests waiting on you, `me`, reviews included, oldest first, none of
// which another request gathers from below: one question climbing is one item,
// at its top.
function queue(requests, me) {
  const hidden = Requests.contained(requests);
  return requests.filter(request => Requests.pending(request) && Requests.forYou(request, me) && !hidden.has(request.id))
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

// How a pending item reads: {id, kind, word, icon, asker, line, path,
// work, title, body, unblocks, grants, since, asks}; `line` says from whom
// and for whom, as Requests.line does. `input`: {me (the viewer), flat (progress
// nodes), front (the agent the person talks with), noted (request id -> true
// for one the harness passed on), folder (the root of the work's workspace),
// text (the question as its readers see it)}.
function describe(request, input) {
  const kind = Requests.shape(request);
  const look = Requests.marks[kind];
  const asker = Requests.asker(request);
  const node = nodeOf(request, input.flat || []);
  const work = node ? node.title : "";
  const route = path(request, input);
  const form = kind === "needs-you" ? Questions.parse(input.text) : null;
  const wanted = Requests.granted(request);
  const unlocks = wanted ? Requests.unlocks(wanted, input.folder) : "";
  const above = route.slice(0, -1);
  const held = request.interception;
  const lead = wanted || form || held ? null : sentence(headline(input.text));
  const unblocks = [asker + " resumes " + (work !== "" ? work : "its work")]
    .concat(above.length > 0 ? [names(above) + (above.length > 1 ? " are" : " is") + " waiting for it"] : []).join(" · ");
  return {
    id: request.id, kind: kind, word: look.text, icon: look.icon,
    asker: asker, line: Requests.line(request, input.me), path: route, work: work,
    title: held ? capital(held.summary) : wanted ? capital(asker) + " asks to " + unlocks : form ? capital(asker) + " asks " + form.items.length + " questions" : lead.first,
    body: lead ? [lead.more, rest(input.text)].filter(part => part !== "").join("\n\n") : "",
    unblocks: held ? asker + " waits for your review" : unblocks,
    grants: wanted && Object.keys(request.options || {}).includes("grant") ? unlocks + " · this work only" : unlocks,
    since: request.created_at || "",
    asks: form ? form.items.length : 1
  };
}

// A request's options split as its action group shows them: the ones given
// once, the no or cancel, and, for a permission, the wider scopes behind
// "Always…". `primary` is the card's filled button, one of those given once:
// a grant, an approval or an acceptance, else the first that does not say no
// or ask for changes (Requests.negative); "" only when every one does.
function actions(options, permission) {
  const once = Requests.once(options, permission);
  return { once: once, primary: once.find(option => ["grant", "approve", "accept"].includes(option)) || once.find(option => !Requests.negative(option)) || "", denies: options.filter(Requests.guarded), always: Requests.always(options, permission) };
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
  if (Requests.review(request)) {
    const words = { approve: ["check", "APPROVED", "approved"], edit: ["edit", "EDITED", "edited and approved"], deny: ["close", "DENIED", "denied"] }[option] || ["diamond", "ANSWERED", "answered"];
    return { icon: words[0], word: words[1], sentence: "You " + words[2] + ": " + request.interception.summary + where };
  }
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

// A work as its card in the chat reads: {work, title, state, word, waits,
// elapsed}. `waits` is who it waits for, as a sentence, or ""; `at` is the
// clock in seconds.
function workCard(node, at) {
  return {
    work: node.work, title: node.title, state: node.state, word: stateWord(node),
    waits: node.state === "waiting" && node.waitingOn ? node.agent + " is waiting for " + node.waitingOn : "",
    elapsed: Progress.span(Progress.closed(node.state) ? node.own.seconds : Math.max(0, at - node.created))
  };
}
