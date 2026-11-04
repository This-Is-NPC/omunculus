.pragma library

function pending(request) { return request.status === "pending"; }
function human(participant) { return participant.kind === "human"; }
function label(participant) {
  return human(participant) ? participant.issuer + ":" + participant.subject : participant.agent;
}

// An answer with words and an option; given the part names of an escalated
// request's origins down to the request the option is of, the option goes
// there, each level carrying the words.
function answer(option, body, path) {
  const value = { body: body || option };
  if (option) value.option = option;
  return (path || []).reduceRight((inner, part) => {
    const parts = {};
    parts[part] = inner;
    return { body: value.body, parts: parts };
  }, value);
}

// The decisions a request offers: its own options, then, of every request it
// gathers from below still waiting, the options named there, each with the
// parts that lead to it and the request it is of, as an escalation keeps a
// decision's options on its origin.
function choices(request, path) {
  const at = path || [];
  const own = Object.keys(request.options || {});
  const mine = own.length > 0 && (at.length === 0 || ["pending", "escalated"].includes(request.status))
    ? [{ part: at.length > 0 ? at[at.length - 1] : "", path: at, options: own, request: request }] : [];
  return Object.keys(request.origins || {})
    .reduce((all, part) => all.concat(choices(request.origins[part], at.concat([part]))), mine);
}

// The option a reply chose: its own, or the first one its parts chose.
function chosen(answer) {
  if (answer.option) return answer.option;
  const parts = Object.values(answer.parts || {}).map(part => chosen(part)).filter(option => option);
  return parts.length > 0 ? parts[0] : "";
}

// The first name a grant among a request's decisions gives, as {kind, name};
// null when none grants.
function granted(request) {
  for (const choice of choices(request))
    for (const option of choice.options)
      for (const step of choice.request.options[option])
        if (step.name === "grant") return step.args;
  return null;
}

// Whether an event is the harness opening a request, as when an agent left a
// question unanswered and the harness passed it on to whoever is next: such
// a request is no one's words.
function byHarness(event) {
  return event.type === "request" && !!event.request_id && !!event.actor && event.actor.kind === "harness";
}

// What a request the harness opened passes on: the origins it gathers that
// ask something, each with its question and whoever asked it; the request's
// own reason only says how it came to you.
function passedOn(request) {
  return Object.keys(request.origins || {}).map(part => request.origins[part])
    .filter(origin => String(origin.reason || "").trim() !== "");
}

// The ids of every request some other request gathers from below through its
// `origins`, at any depth: they are one question climbing, shown once, on the
// request at the top.
function contained(requests) {
  const ids = new Set();
  const visit = request => Object.values(request.origins || {}).forEach(origin => {
    if (origin.id) ids.add(origin.id);
    visit(origin);
  });
  requests.forEach(visit);
  return ids;
}

// Whether a request gathers the request `id` through its origins, at any depth.
function gathers(request, id) {
  return Object.values(request.origins || {}).some(origin => origin.id === id || gathers(origin, id));
}

// Who holds an open question now: the request itself while it is pending,
// else the pending request of `requests` that gathers it, at any depth, as
// one escalated climbs; null when it is not open or nothing holds it yet.
function holder(request, requests) {
  if (pending(request)) return request;
  if (request.status !== "escalated") return null;
  return requests.find(other => pending(other) && gathers(other, request.id)) || null;
}

// The works a question climbed from: its own and those of its origins, at
// any depth, each once, its own first.
function works(request) {
  const found = [];
  const visit = each => {
    if (each.work_id && !found.includes(each.work_id)) found.push(each.work_id);
    Object.values(each.origins || {}).forEach(visit);
  };
  visit(request);
  return found;
}

// What a request asks of you: "permission" when a decision grants, "decision"
// when it offers options, "needs-you" for a free answer; "team" when it is not
// pending on a person.
function kind(request) {
  if (!pending(request) || !human(request.arbiter)) return "team";
  if (granted(request) !== null) return "permission";
  return choices(request).length > 0 ? "decision" : "needs-you";
}

// The climb of a request, nearest origin first: each origin's requester and
// question, depth first.
function chain(request) {
  return Object.keys(request.origins || {}).reduce((all, part) => {
    const origin = request.origins[part];
    return all.concat([{ requester: origin.requester, reason: origin.reason }], chain(origin));
  }, []);
}

// Who asked the question in a request: the deepest origin it climbed from, else
// its own requester; a name for the card, the answered line and the strip.
function asker(request) {
  const climb = chain(request);
  return label((climb.length > 0 ? climb[climb.length - 1] : request).requester);
}
