.pragma library
.import "Phrases.js" as Phrases

function pending(request) { return request.status === "pending"; }
function human(participant) { return !!participant && participant.kind === "human"; }
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

// An option as a button reads it: its words in capitals.
function optionText(option) { return option.replace(/[-_]/g, " ").toUpperCase(); }

// An option as its card button and quick chip read it. `of` names where a
// scope applies: {who, stage, folder}.
function optionLabel(option, of) {
  const at = of || {};
  return ({
    grant: "GRANT" + "\u00a0\u00b7\u00a0THIS WORK ONLY",
    grant_agent: "FOR " + String(at.who || "").toUpperCase(),
    grant_stage: "IN THE " + String(at.stage || "").toUpperCase() + " STAGE",
    grant_workspace: at.folder ? "IN FOLDER " + at.folder : "IN THE PROJECT",
    deny: "DENY"
  })[option] || optionText(option);
}

// A no or a cancel: given last and never as a quick first choice.
function guarded(option) { return option === "deny" || option === "cancel"; }

// Whether an option is a scope a grant is saved for: only a permission's
// grant_* options are; a decision may name its own options so.
function scoped(option, permission) { return !!permission && option.startsWith("grant_"); }

// The scopes a grant is saved for, always, of a permission. The depth scope
// names an agent's level, not anyone the person knows, so it is not offered.
function always(options, permission) { return options.filter(option => scoped(option, permission) && option !== "grant_depth"); }

// A decision's options given once, as its card shows them: a grant first,
// then the rest in order, apart from a no or a cancel and the saved scopes.
function once(options, permission) {
  const rest = options.filter(option => option !== "grant" && !scoped(option, permission) && !guarded(option));
  return (options.includes("grant") ? ["grant"] : []).concat(rest);
}

// Every option in the card's order: those given once, then a no or a cancel.
function ordered(options, permission) { return once(options, permission).concat(options.filter(guarded)); }

// What the heading of your answer says of the option you chose; "" for an
// answer in words. Adjusting is asking for changes, not choosing. A grant
// keeps its scope: `of` ({who, stage, folder}) says where a saved one applies.
function chose(option, permission, of) {
  if (!option) return "";
  if (option === "adjust") return "YOU ASKED TO ADJUST";
  if (option === "grant") return "YOU GRANTED  \u00b7  THIS WORK ONLY";
  if (scoped(option, permission)) return "YOU GRANTED  \u00b7  " + optionLabel(option, of);
  return "YOU CHOSE " + optionText(option);
}

// What a granted name, as {kind, name}, lets the agent do; `root` is its
// workspace's folder.
function unlocks(granted, root) {
  if (!granted) return "";
  if (granted.kind === "resource")
    return { "sandbox.write": "write files in " + (root || "its workspace"), "sandbox.network": "use the network" }[granted.name] || "use " + granted.name;
  if (granted.kind === "tool")
    return Phrases.act(granted.name) || granted.name.replace(/_/g, " ");
  return "reach " + granted.name;
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

// What a request asks, in its asker's words: when `noted` says the harness
// opened it, the questions it passes on, joined with a blank line; else its
// own reason.
function question(request, noted) {
  const passed = noted ? passedOn(request) : [];
  return passed.length > 0 ? passed.map(origin => origin.reason).join("\n\n") : String(request.reason || "");
}

// The request this one repeats: the one asked just before it and already
// answered, from the same asker on the same work at the same stage, offering
// the same options and, when they grant, the same thing, given `replies` by request id; null when none, or when
// the requests carry no time to tell them by. Another decision of that asker
// (the proposal after the preview) is no repeat.
function repeated(request, requests, replies) {
  const work = request.work_id || "";
  const who = asker(request);
  const offered = each => JSON.stringify(choices(each).map(choice => choice.options.slice().sort()));
  const before = requests.filter(each => each.id !== request.id && !pending(each) && replies[each.id]
    && (each.work_id || "") === work && asker(each) === who
    && (each.stage || "") === (request.stage || "") && offered(each) === offered(request)
    && JSON.stringify(granted(each)) === JSON.stringify(granted(request))
    && !!each.created_at && !!request.created_at && each.created_at < request.created_at)
    .sort((a, b) => a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : 0);
  return before.length > 0 ? before[before.length - 1] : null;
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

// The asker first, then who passed the question on toward you ("design-lead",
// "seller", "sales"); the request's own requester only closes the line unless
// `noted` says the person already saw it as a note.
function route(request, noted) {
  const names = chain(request).reverse().map(level => label(level.requester));
  if (!noted) names.push(label(request.requester));
  return names.filter((name, at) => name && names.indexOf(name) === at);
}
