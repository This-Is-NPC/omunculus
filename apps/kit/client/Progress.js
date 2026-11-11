.pragma library
.import "Requests.js" as Requests
.import "Questions.js" as Questions
.import "Phrases.js" as Phrases
.import "Usage.js" as Usage
.import "Time.js" as Time

// Where the conversation's works are, derived from the state and the stage
// events and never stored. Times are in seconds.

const words = {
  working: "Working", "needs-you": "Needs you", waiting: "Waiting", stopped: "Stopped",
  failed: "Failed", done: "Done", "up-next": "Up next", cancelled: "Cancelled", idle: ""
};
// Which state wins, first highest: for the conversation and for the path down.
const order = ["needs-you", "working", "waiting", "stopped", "failed", "up-next"];
const glyphs = { done: "✓", current: "●", next: "○" };

// The word a state shows: "Working", "Needs you", ...
function word(state) { return words[state] || ""; }

// An ISO stamp or seconds as seconds; null for neither.
function seconds(value) {
  if (typeof value === "number") return value;
  const parsed = typeof value === "string" ? Date.parse(value) : NaN;
  return isNaN(parsed) ? null : parsed / 1000;
}

function firstLine(text) { return String(text || "").split("\n")[0].trim(); }

// A duration in words: "42 s", "3 min", "1 h 05 min".
function span(total) {
  const s = Math.max(0, Math.floor(total));
  if (s < 60) return s + " s";
  if (s < 3600) return Math.floor(s / 60) + " min";
  return Math.floor(s / 3600) + " h " + Time.two(Math.floor(s % 3600 / 60)) + " min";
}

// A duration in plain words: "8 seconds", "1 minute", "1 hour 5 minutes".
function duration(total) {
  const s = Math.max(0, Math.floor(total));
  const said = (count, unit) => count + " " + unit + (count === 1 ? "" : "s");
  if (s < 60) return said(s, "second");
  if (s < 3600) return said(Math.floor(s / 60), "minute");
  const minutes = Math.floor(s % 3600 / 60);
  return said(Math.floor(s / 3600), "hour") + (minutes > 0 ? " " + said(minutes, "minute") : "");
}

// What a run does at `now` (seconds): one that has made no call for a while
// thinks, it is past getting started.
function lively(doing, since, now) {
  return doing === "Getting started" && since !== null && now - since > 15 ? "Thinking" : doing;
}

// The agents of `path` above `agent`, from the top: those it works under.
function above(path, agent) {
  const names = path.map(step => step.agent).filter(name => name);
  const at = names.indexOf(agent);
  return (at >= 0 ? names.slice(0, at) : names.filter(name => name !== agent)).filter((name, index, all) => all.indexOf(name) === index);
}

// Who works for a thread at the moment, as the thread's live entry says it:
// {chain, agent, doing, since, round}, the agents above the one at work, from
// the top, that one, what it does and since when; null when no one works for
// it. The main thread ("") is the front agent's, which heads the chain of the
// works below it; its own run outside any work stands alone. A work's thread
// names the chain from that work down, or its own agent while it works.
function live(progress, thread, front) {
  if (!progress || !progress.now || progress.now.state !== "working" || !progress.now.agent) return null;
  const now = progress.now;
  const entry = chain => ({ chain: chain.filter((name, at) => name && name !== now.agent && chain.indexOf(name) === at), agent: now.agent, doing: now.doing, since: now.since, round: now.round || 0 });
  const path = progress.path || [];
  if (thread === "") {
    const onPath = path.some(step => step.agent === now.agent);
    return entry(now.loose && !onPath ? [] : [front].concat(above(path, now.agent)));
  }
  const from = path.findIndex(step => step.work === thread);
  if (from >= 0 && path.slice(from).some(step => step.agent === now.agent)) return entry(above(path.slice(from), now.agent));
  const node = (progress.flat || []).find(each => each.work === thread);
  return node && node.state === "working"
    ? { chain: [], agent: node.agent, doing: node.doing, since: node.since, round: node.round || 0 } : null;
}

// How a run reads in one line, from its status and the lines the runs command
// printed under it: {state, text} in the words of a work's state and capitals.
function outcome(status, lines) {
  if (status === "open") return { state: "working", text: "RUNNING" };
  if (lines.includes("ended: stopped without end")) return { state: "stopped", text: "STOPPED WITHOUT END" };
  const failed = lines.filter(line => line.startsWith("failed:")).length;
  return { state: "done", text: "ENDED" + (failed > 0 ? " · " + failed + (failed === 1 ? " FAILED CALL" : " FAILED CALLS") : "") };
}

// A running clock: "0:42", "12:05", "1:02:03".
function clock(total) {
  const s = Math.max(0, Math.floor(total));
  const h = Math.floor(s / 3600);
  const m = Math.floor(s % 3600 / 60);
  return h > 0 ? h + ":" + Time.two(m) + ":" + Time.two(s % 60) : m + ":" + Time.two(s % 60);
}

// `text` in at most `budget` characters, ending in "…" when cut.
function elide(text, budget) {
  if (text.length <= budget) return text;
  return budget <= 0 ? "" : text.slice(0, budget - 1) + "…";
}

// Who an event's actor is: an agent by its name, the harness as "harness",
// the viewer as "you" and any other person by identity; "" for an event
// without one.
function actorOf(event, me) {
  const actor = event.actor || {};
  if (actor.kind === "human" && me && !Requests.isMe(actor, me)) return Requests.label(actor);
  return actor.kind === "agent" ? actor.id || "" : actor.kind === "harness" ? "harness" : actor.kind ? "you" : "";
}

// Adds a stage event to the journeys (work id -> {entered: [{stage, at,
// round, from?}], rounds, stopped, sentBack, finishedAt}); the same object
// back for any other event, so nothing recomputes.
function journal(journeys, event) {
  const type = event.type;
  const id = event.work_id || "";
  if (!["continue", "reopen", "break"].includes(type) || id === "") return journeys;
  const body = event.body || {};
  const at = seconds(event.at);
  const was = journeys[id] || { entered: [], rounds: 0, stopped: null, sentBack: null, finishedAt: null };
  const journey = Object.assign({}, was, { entered: was.entered.slice() });
  const round = rounds => rounds > 0 ? rounds + 1 : 0;
  if (type === "continue") {
    if (body.to) {
      const entry = { stage: body.to, at: at, round: round(journey.rounds) };
      if (journey.entered.length === 0 && body.from) entry.from = body.from;
      journey.entered.push(entry);
    } else {
      journey.finishedAt = at;
    }
    journey.stopped = null;
  } else if (type === "reopen") {
    journey.rounds = was.rounds + 1;
    journey.entered.push({ stage: body.stage || "", at: at, round: round(journey.rounds) });
    journey.sentBack = was.stopped || { by: actorOf(event), why: "", at: at };
    journey.stopped = null;
    journey.finishedAt = null;
  } else {
    journey.stopped = { by: actorOf(event), why: firstLine(body.body), at: at };
  }
  const next = Object.assign({}, journeys);
  next[id] = journey;
  return next;
}

function plus(a, b) {
  const sum = Object.assign({}, a);
  for (const key of Object.keys(b || {}))
    if (typeof b[key] === "number") sum[key] = (sum[key] || 0) + b[key];
  return sum;
}

function counted(nodes) {
  return {
    working: nodes.filter(node => node.state === "working").length,
    waiting: nodes.filter(node => node.state === "waiting" || node.state === "needs-you").length,
    done: nodes.filter(node => node.state === "done").length,
    total: nodes.length
  };
}

function rank(state) {
  const at = order.indexOf(state);
  return at < 0 ? order.length : at;
}

function closed(state) { return state === "done" || state === "cancelled"; }

// The stage intervals of a work in a workflow, oldest first: {stage, from, to}.
function intervals(lane, journey, created, end) {
  const entered = journey ? journey.entered : [];
  const first = entered.length === 0 ? lane.steps[lane.at].name
    : entered[0].from || lane.steps[0].name;
  const starts = [{ stage: first, at: created }].concat(entered);
  return starts.map((start, i) => ({
    stage: start.stage, from: start.at, to: i + 1 < starts.length ? starts[i + 1].at : end
  }));
}

// The conversation's progress, {state, roots, focus, flat, path, now,
// forYou, agents, counts, spoken, front}: one node per work, nested under the stage
// that handed it down, with what it does, what it waits on and what its
// branch spent; the root to show, the path to the work active below it, what
// waits on you, as its card asks it, and the agents that ran, first first;
// `front`, the agent that talks with the person when the works are other
// agents' ({agent, agents, asking, ask, asker, state, doing, since}), else null. A node's `calls` are its
// tool calls, shown as steps: the model calls are in `usage`.
// input: {works, lanes (work id -> laneOf), runs (with error), requests,
// noted (request id -> true for one the harness passed on), calling,
// callArgs, runStarts, journeys, rootAgent, me (the viewer), now, usage (work id -> Usage
// tally), calls (work id -> tool calls {count, failed, last: {text, at}})}.
function build(input) {
  const works = input.works || [];
  const lanes = input.lanes || {};
  const runs = input.runs || [];
  const calling = input.calling || {};
  const callArgs = input.callArgs || {};
  const starts = input.runStarts || {};
  const journeys = input.journeys || {};
  const usage = input.usage || {};
  const callsOf = input.calls || {};
  const noted = input.noted || {};
  const me = input.me || null;
  const now = input.now || 0;
  // Per node, while building: the latest end in its branch, its agents and
  // the requests holding its questions.
  const inner = new Map();
  const requests = input.requests || [];
  const pending = requests.filter(Requests.pending);
  const known = new Set(works.map(work => work.id));
  const runStart = run => starts[run.id] !== undefined ? starts[run.id] : seconds(run.started_at);
  const runsOf = id => runs.filter(run => (run.work_id || "") === id);
  // What an open run on a work is doing: a call is recorded once it finished,
  // but the model event that asked for it is known, so while it runs it says
  // that call; between calls it thinks, after the last one it made; a reply
  // says what it does, by whom it answers.
  const phrasing = id => {
    // A call the model asked for that has not answered is what it does now.
    const asked = (input.asked || {})[id] || [];
    if (asked.length > 0) return Phrases.phrase(asked[0].name, asked[0].args);
    if (!calling[id]) return "Getting started";
    if (calling[id] !== "reply") {
      const last = Phrases.did(calling[id], callArgs[id]);
      return "Thinking · " + last.charAt(0).toLowerCase() + last.slice(1);
    }
    const answered = requests.find(request => request.id === (callArgs[id] || {}).request_id);
    return Phrases.replied(answered && answered.requester ? answered.requester.agent || "" : "", given(requests, answered, noted, me));
  };

  const node = (work, level) => {
    const id = work.id;
    const lane = lanes[id] || null;
    const journey = journeys[id] || null;
    const mine = runsOf(id);
    const run = mine.filter(each => each.status === "open").pop() || null;
    const lastRun = mine[mine.length - 1] || null;
    // Its open questions, each as the request that holds it now.
    const asking = [];
    for (const request of requests) {
      const holder = (request.work_id || "") === id ? Requests.holder(request, requests) : null;
      if (holder && !asking.includes(holder)) asking.push(holder);
    }
    const created = seconds(work.created_at) || 0;
    const finishedAt = journey && journey.finishedAt !== null ? journey.finishedAt : null;
    const end = finishedAt !== null ? finishedAt
      : closed(work.state) ? seconds(work.updated_at) || now : now;
    const kids = works.filter(item => item.parent_id === id)
      .map(item => node(item, level + 1))
      .sort((a, b) => a.created - b.created);

    let state = "up-next";
    let waitingOn = "";
    if (run) state = "working";
    else if (asking.some(request => Requests.forYou(request, me))) state = "needs-you";
    else if (work.state === "cancelled") state = "cancelled";
    else if (work.state === "done") state = "done";
    else if (work.state === "broken" || (work.state === "waiting" && !work.waiting))
      state = lastRun && lastRun.error ? "failed" : "stopped";
    else if (asking.length > 0) {
      state = "waiting";
      waitingOn = Array.from(new Set(asking.map(request => Requests.label(request.arbiter)))).join(", ");
    } else if (work.state === "waiting" && work.waiting === "child") {
      state = "waiting";
      waitingOn = Array.from(new Set(kids.filter(kid => !closed(kid.state)).map(kid => kid.agent))).join(", ");
    } else if (work.state === "waiting" && work.waiting === "message") {
      state = "waiting";
      waitingOn = "a message";
    } else if (work.state === "waiting" && work.waiting) {
      state = "waiting";
      waitingOn = "an answer";
    }

    const agent = run ? run.agent : lane ? lane.steps[lane.at].agent : work.assignee || "";
    const stopped = journey ? journey.stopped : null;
    const ownSeconds = Math.max(0, end - created);
    const finishedIn = state === "done" ? ownSeconds : null;
    let doing = "";
    if (state === "working") doing = phrasing(id);
    else if (state === "needs-you") doing = "Waiting for your answer";
    else if (state === "waiting") doing = "Waiting for " + (waitingOn || "the team");
    else if (state === "stopped") doing = stopped ? "Sent back for fixes" + (stopped.by && stopped.by !== agent ? " by " + stopped.by : "") + (stopped.why ? ": " + stopped.why : "") : "Stopped";
    else if (state === "failed") doing = "Failed: " + firstLine(lastRun.error);
    else if (state === "done") doing = "Done in " + span(finishedIn);
    else if (state === "cancelled") doing = "Cancelled";
    else if (state === "up-next") doing = "Up next";

    // Stages, and the children each was current for.
    const spans = lane ? intervals(lane, journey, created, end) : [];
    const groups = [];
    const placed = spans.map(() => []);
    for (const kid of kids) {
      let at = spans.findIndex((each, i) => kid.created >= each.from
        && (kid.created < each.to || (i === spans.length - 1 && kid.created <= each.to)));
      if (at < 0) at = spans.length - 1;
      if (at >= 0) placed[at].push(kid);
    }
    if (lane) spans.forEach((each, i) => {
      if (placed[i].length > 0) groups.push({ step: each.stage, nodes: placed[i], parallel: placed[i].length > 1, counts: counted(placed[i]) });
    });
    else if (kids.length > 0) groups.push({ step: "", nodes: kids, parallel: kids.length > 1, counts: counted(kids) });
    const steps = lane ? lane.steps.map((step, i) => {
      const status = work.state === "done" || i < lane.at ? "done" : i === lane.at ? "current" : "next";
      const spent = spans.filter(each => each.stage === step.name).reduce((sum, each) => sum + Math.max(0, each.to - each.from), 0);
      return {
        name: step.name, agent: step.agent, status: status, seconds: spent, again: status === "next" && spent > 0,
        children: [].concat.apply([], spans.map((each, j) => each.stage === step.name ? placed[j] : []))
      };
    }) : [];

    const team = lane
      ? Array.from(new Set(lane.steps.map(step => step.agent))).map(name => ({ agent: name, current: name === agent }))
      : [{ agent: work.assignee || agent, current: true }];
    const tally = callsOf[id] || { count: 0, failed: 0, last: null };
    const agentSeconds = mine.reduce((sum, each) => {
      const from = runStart(each);
      const to = each.status === "open" ? now : seconds(each.finished_at);
      return from === null || to === null ? sum : sum + Math.max(0, to - from);
    }, 0);
    const own = { seconds: ownSeconds, agentSeconds: agentSeconds, calls: tally.count, failed: tally.failed, usage: plus(Usage.tally(), usage[id]) };
    const agents = new Set(mine.map(each => each.agent));
    kids.forEach(kid => inner.get(kid).agents.forEach(name => agents.add(name)));
    const reach = kids.reduce((latest, kid) => Math.max(latest, inner.get(kid).reach), end);
    const branch = kids.reduce((sum, kid) => ({
      agentSeconds: sum.agentSeconds + kid.branch.agentSeconds,
      works: sum.works + kid.branch.works,
      usage: plus(sum.usage, kid.branch.usage),
      running: sum.running + kid.branch.running,
      calls: sum.calls + kid.branch.calls
    }), { agentSeconds: agentSeconds, works: 1, usage: own.usage, running: mine.filter(each => each.status === "open").length, calls: own.calls });
    branch.seconds = Math.max(0, reach - created);
    branch.agents = agents.size;

    let since = null;
    if (run) since = runStart(run);
    else if (!closed(state)) since = seconds(work.updated_at);

    const made = {
      work: id, title: work.title || "", level: level, parent: work.parent_id || "", agent: agent,
      state: state, word: word(state), waitingOn: waitingOn, since: since, doing: doing,
      lastStep: calling[id] ? Phrases.said(calling[id], callArgs[id]) : "",
      workflow: lane ? lane.name : "", steps: steps, at: lane ? lane.at : -1, count: lane ? lane.steps.length : 0,
      round: journey && journey.rounds > 0 ? journey.rounds + 1 : 0,
      sentBack: journey ? journey.sentBack : null, stopped: state === "stopped" ? stopped : null,
      asks: [], asked: [], below: "", calls: tally.count, failed: tally.failed,
      children: lane ? [] : kids, groups: groups, team: team, last: tally.last || null,
      own: own, branch: branch, finishedIn: finishedIn, created: created
    };
    inner.set(made, { reach: reach, agents: agents, asking: asking });
    return made;
  };

  const newest = (a, b) => b.created - a.created;
  const built = works.filter(work => !work.parent_id || !known.has(work.parent_id)).map(work => node(work, 0));
  const roots = built.filter(each => !closed(each.state)).sort(newest)
    .concat(built.filter(each => closed(each.state)).sort(newest));
  const flat = [];
  const visit = each => { flat.push(each); kidsOf(each).forEach(visit); };
  roots.forEach(visit);
  const byWork = {};
  flat.forEach(each => { byWork[each.work] = each; });

  // The work a pending request's climb started from: the deepest of the
  // works it climbed from.
  const askerOf = request => Requests.works(request).map(id => byWork[id]).filter(each => each)
    .reduce((deepest, each) => !deepest || each.level > deepest.level ? each : deepest, null);

  // One question counts once: only the work that asks it needs you. The works
  // it climbed through wait for your answer to it.
  for (const each of flat) {
    if (each.state !== "needs-you") continue;
    const mine = inner.get(each).asking.filter(request => Requests.forYou(request, me));
    if (mine.some(request => askerOf(request) === each)) continue;
    const asker = askerOf(mine[0]);
    each.state = "waiting";
    each.word = word("waiting");
    each.waitingOn = "you";
    each.doing = "Waiting for your answer to " + (asker ? asker.agent : "the team");
  }

  // Each pending request: on the node that asked it, and on the nearest node
  // at or above the asking one whose agent decides it.
  for (const request of pending) {
    const asker = askerOf(request);
    if (!asker) continue;
    const you = Requests.forYou(request, me);
    let to = null;
    if (!you) {
      const arbiter = Requests.label(request.arbiter);
      for (let at = asker; at && !to; at = byWork[at.parent]) if (at.agent === arbiter) to = at;
    }
    const chain = Requests.chain(request).map(origin => Requests.label(origin.requester)).reverse()
      .concat([Requests.label(request.requester), Requests.party(request.arbiter, me)]);
    asker.asks.push({
      id: request.id, to: Requests.party(request.arbiter, me), forYou: you,
      question: request.reason || "", toWork: to ? to.work : null, chain: chain,
      mark: Requests.mark(request)
    });
    const form = Requests.shape(request) === "needs-you" ? Questions.parse(request.reason || "") : null;
    if (to) to.asked.push({ id: request.id, mark: Requests.mark(request), from: Requests.label(request.requester), fromWork: asker.work, question: request.reason || "", asks: form ? form.items.length : 1 });
  }

  // Above a work that needs you, each work that does not hold its question
  // says so, keeping its own state.
  for (const each of flat) {
    if (each.state !== "needs-you") continue;
    const ask = each.asks.find(item => item.forYou);
    for (let at = byWork[each.parent]; at && ask; at = byWork[at.parent])
      if (at.below === "" && !inner.get(at).asking.some(request => request.id === ask.id)) at.below = ask.id;
  }

  const hidden = Requests.contained(requests);
  // A request the harness passed on asks what its origins asked; a numbered
  // question asks each of its items.
  const forYou = pending.filter(request => Requests.forYou(request, me) && !hidden.has(request.id)).map(request => {
    const of = askerOf(request);
    const question = Requests.question(request, noted[request.id]);
    const kind = Requests.kind(request, me);
    const form = kind === "needs-you" ? Questions.parse(question) : null;
    return {
      id: request.id, asker: Requests.asker(request), again: Requests.repeated(request, requests, input.replies || {}) !== null,
      work: of ? of.work : "", title: of ? of.title : "", question: question, kind: kind, mark: Requests.mark(request), asks: form ? form.items.length : 1
    };
  });

  const focus = roots.length === 0 ? null : roots[0];
  const path = [];
  for (let at = focus; at; ) {
    path.push({ agent: at.agent, title: at.title, work: at.work });
    at = kidsOf(at).filter(kid => !closed(kid.state)).sort((a, b) => rank(a.state) - rank(b.state) || newest(a, b))[0] || null;
  }
  const leaf = path.length > 0 ? byWork[path[path.length - 1].work] : null;
  const open = runs.filter(run => run.status === "open");
  const loose = open.filter(run => !(run.work_id || "")).pop() || null;
  let doing = { agent: input.rootAgent || "", doing: "", since: null, state: "idle" };
  if (leaf && (leaf.state === "working" || leaf.state === "needs-you")) doing = { agent: leaf.agent, doing: leaf.doing, since: leaf.since, state: leaf.state, round: leaf.round };
  else if (loose) doing = {
    agent: loose.agent || input.rootAgent || "",
    doing: phrasing(""),
    since: runStart(loose), loose: true, state: "working"
  };
  else if (open.length > 0) {
    // An open run outranks a closed leaf: the agent that works now.
    const run = open[open.length - 1];
    doing = { agent: run.agent || input.rootAgent || "", doing: phrasing(run.work_id || ""), since: runStart(run), state: "working" };
  } else if (leaf) doing = { agent: leaf.agent, doing: leaf.doing, since: leaf.since, state: leaf.state, round: leaf.round };

  const lastRun = runs[runs.length - 1];
  let state = "idle";
  if (forYou.length > 0) state = "needs-you";
  else if (open.length > 0) state = "working";
  else if (flat.some(each => each.state === "waiting")) state = "waiting";
  else if (flat.some(each => each.state === "stopped")) state = "stopped";
  else if (flat.some(each => each.state === "failed") || (lastRun && lastRun.error)) state = "failed";
  else if (roots.length > 0 && roots.every(each => closed(each.state)) && roots.some(each => each.state === "done")) state = "done";

  const agents = Array.from(new Set(runs.map(run => run.agent).filter(name => name)));
  const counts = counted(flat);
  counts.agents = agents.length;
  let spoken = "";
  if (state === "needs-you") spoken = forYou[0].asker + " asks you: " + firstLine(forYou[0].question);
  else if (state !== "idle") spoken = word(state) + ". " + above(path, doing.agent).concat([doing.agent]).join(", ") + (doing.doing ? ": " + doing.doing : "");

  // The agent that talks with the person, when its works are other agents':
  // the root of the team, what it asks the person and its own state.
  const talking = input.rootAgent ? open.find(run => run.agent === input.rootAgent) : null;
  const delegated = Array.from(new Set(roots.filter(each => !closed(each.state) && each.agent !== input.rootAgent).map(each => each.agent)));
  const front = input.rootAgent && roots.some(each => each.agent !== input.rootAgent)
    ? {
      agent: input.rootAgent, agents: agents.length, asking: asking(forYou), ask: forYou.length > 0 ? forYou[0].id : "", asker: forYou.length > 0 ? forYou[0].asker : "", mark: forYou.length > 0 ? forYou[0].mark : null,
      state: talking ? "working" : forYou.length > 0 ? "needs-you" : delegated.length > 0 ? "waiting" : "idle",
      doing: talking ? phrasing(talking.work_id || "") : delegated.length > 0 && forYou.length === 0 ? "Waiting for " + delegated.join(", ") : "",
      since: talking ? runStart(talking) : null
    }
    : null;

  return { state: state, roots: roots, focus: focus, flat: flat, path: path, now: doing, forYou: forYou, agents: agents, counts: counts, spoken: spoken, front: front };
}

// Where a work is in its workflow: {workflow, step, steps, stage}, the step
// counted from 1 and the last once the work is done; null in none.
function track(node) {
  if (node.count === 0) return null;
  const at = Math.min(Math.max(node.at, 0), node.count - 1);
  return { workflow: node.workflow, step: node.state === "done" ? node.count : at + 1, steps: node.count, stage: node.steps[at].name };
}

// Where the conversation stands, for its head: {workflow, stage, step, steps,
// chain, agent, state, waits}: the track of the work in focus; `chain`, the
// agents from the front one down to the one at work or waited for, each once,
// and `agent`, the one it ends on; `waits`, what a conversation that waits
// waits on: "you", or what the work in focus waits for, as its card says it,
// "" otherwise; `asker`, the deepest agent that asks you. null before any
// work.
function standing(progress, front) {
  const focus = progress ? progress.focus : null;
  if (!focus) return null;
  const working = live(progress, "", front);
  const names = working ? working.chain.concat([working.agent]) : [front].concat(progress.path.map(step => step.agent));
  const chain = names.filter((name, index, all) => name && all.indexOf(name) === index);
  const state = progress.state;
  const asking = progress.flat.filter(node => node.state === "needs-you").sort((a, b) => b.level - a.level)[0];
  // What the work in focus waits on, as its card says it; else, what any waits on.
  const waits = state === "needs-you" ? "you"
    : state === "waiting" ? focus.waitingOn || Array.from(new Set(progress.flat.filter(node => !closed(node.state) && node.waitingOn).map(node => node.waitingOn))).join(", ")
    : "";
  return Object.assign({ workflow: "", stage: "", step: 0, steps: 0 }, track(focus), { chain: chain, agent: chain[chain.length - 1] || "", state: state, waits: waits, asker: asking ? asking.agent : "" });
}

// How many answers of yours a reply passes on: 0 when you answered none, else
// the items of the numbered question answered, or one.
function given(requests, answered, noted, me) {
  if (!requests.some(request => Requests.forYou(request, me) && !Requests.pending(request))) return 0;
  const form = answered ? Questions.parse(Requests.question(answered, noted[answered.id])) : null;
  return form ? form.items.length : 1;
}

// What requests for you ask (forYou entries), in words after "asks you":
// "7 questions", "to decide", "for a permission"; mixed or several of a
// kind, counted: "7 questions, 2 decisions".
function asking(asks) {
  const count = kind => asks.filter(ask => ask.kind === kind).reduce((sum, ask) => sum + ask.asks, 0);
  const counted = [["needs-you", "question"], ["decision", "decision"], ["permission", "permission"], ["review", "review"]]
    .map(([kind, noun]) => ({ kind: kind, noun: noun, n: count(kind) })).filter(each => each.n > 0);
  if (counted.length === 1 && counted[0].n === 1 && counted[0].kind !== "needs-you")
    return { decision: "to decide", permission: "for a permission", review: "for your review" }[counted[0].kind];
  return counted.map(each => each.n + " " + each.noun + (each.n === 1 ? "" : "s")).join(", ");
}

// A node's children in tree order: by stage for a work in a workflow.
function kidsOf(node) {
  return node.groups.reduce((all, group) => all.concat(group.nodes), []);
}

// The works working below a node, deepest last: who works for a work that
// waits on its sub-works.
function underway(node) {
  return kidsOf(node).reduce((all, kid) => all.concat(kid.state === "working" ? [kid] : [], underway(kid)), []);
}

// The works a node handed down, in words: "1 sub-work done", "2 sub-works,
// 1 working", "3 sub-works, 1 done", "4 sub-works, 1 working, 3 done", "10 sub-works, 1 working, 8 done, 1
// cancelled"; "" when it has none.
function below(kids) {
  if (kids.length === 0) return "";
  const works = kids.length + (kids.length === 1 ? " sub-work" : " sub-works");
  const working = kids.filter(kid => kid.state === "working").length;
  const done = kids.filter(kid => kid.state === "done").length;
  const cancelled = kids.filter(kid => kid.state === "cancelled").length;
  if (done === kids.length) return works + " done";
  if (cancelled === kids.length) return works + " cancelled";
  const parts = (working > 0 ? [working + " working"] : []).concat(done > 0 ? [done + " done"] : [], cancelled > 0 ? [cancelled + " cancelled"] : []);
  return [works].concat(parts).join(", ");
}

// A group of works handed down together, in words: "3 in parallel · 1
// working · 2 done".
function together(group) {
  const counts = group.counts;
  return [group.nodes.length + " in parallel"]
    .concat(counts.working > 0 ? [counts.working + " working"] : [],
      counts.waiting > 0 ? [counts.waiting + " waiting"] : [],
      counts.done > 0 ? [counts.done + " done"] : [])
    .join(" · ");
}

// How many works `nodes` hold, counting those below them.
function within(nodes) {
  return nodes.reduce((sum, node) => sum + 1 + within(kidsOf(node)), 0);
}

// "9 in all" when works lie below `nodes`, so a fold adds up to the works counted.
function inAll(nodes) {
  const all = within(nodes);
  return all > nodes.length ? [all + " in all"] : [];
}

// Sub-works done and cancelled, folded into one line, in words: "2 sub-works
// done · 18 min · 1 cancelled · 9 in all", the time from the first one's start
// to the last end in their branches, the total when works lie below them.
function finished(nodes) {
  const done = nodes.filter(node => node.state === "done").length;
  const cancelled = nodes.length - done;
  const from = Math.min.apply(null, nodes.map(node => node.created));
  const to = Math.max.apply(null, nodes.map(node => node.created + node.branch.seconds));
  const works = count => count + (count === 1 ? " sub-work " : " sub-works ");
  return [done > 0 ? works(done) + "done" : works(cancelled) + "cancelled", span(to - from)]
    .concat(done > 0 && cancelled > 0 ? [cancelled + " cancelled"] : [], inAll(nodes)).join(" · ");
}

function token(text, status) { return { text: text, status: status }; }

function joined(tokens) { return tokens.map(each => each.text).join(""); }

// The one-line forms of a sequence of steps ({name, status}), longest first;
// the separators are tokens of their own.
function forms(steps, round) {
  const done = steps.filter(step => step.status === "done");
  const current = steps.find(step => step.status === "current") || null;
  const next = steps.filter(step => step.status === "next");
  const sep = token(" › ", "separator");
  const long = current ? current.name + (round > 0 ? " · round " + round : "") : "";
  const short = current ? current.name + (round > 0 ? " r" + round : "") : "";
  const chain = parts => parts.reduce((all, part, i) => i === 0 ? [part] : all.concat([sep, part]), []);
  const named = step => token(glyphs[step.status] + " " + (step === current ? long : step.name), step.status);
  const doneCounted = done.length >= 2 ? [token(glyphs.done + " " + done.length, "done")] : done.map(named);
  const middle = (current ? [named(current)] : []);
  const f1 = chain(steps.map(named));
  const f2 = chain(doneCounted.concat(middle, next.map(named)));
  const f3 = next.length > 1
    ? chain(doneCounted.concat(middle, [named(next[0]), token("+" + (next.length - 1), "next")]))
    : f2;
  const f4 = chain((done.length > 0 ? [token(glyphs.done + done.length, "done")] : [])
    .concat(current ? [token(glyphs.current + " " + short, "current")] : [], next.length > 0 ? [named(next[0])] : []))
    .concat(next.length > 1 ? [token(" ", "separator"), token("+" + (next.length - 1), "next")] : []);
  const dots = steps.reduce((all, step, i) => all.concat(i === 0 ? [] : [token(" ", "separator")], [token(glyphs[step.status], step.status)]), []);
  const f5 = dots.concat(current ? [token("  ", "separator"), token(short, "current")] : []);
  const position = current ? steps.indexOf(current) + 1 : done.length;
  const f6 = [token(position + "/" + steps.length + (current ? " " + short : ""), current ? "current" : "done")];
  return [["F1", f1], ["F2", f2], ["F3", f3], ["F4", f4], ["F5", f5], ["F6", f6]];
}

// The longest form of the sequence that fits `budget` characters, as
// {form, tokens: [{text, status}]}; status is done, current, next or
// separator. The last form elides to fit any budget.
function stepper(steps, round, budget) {
  if (steps.length === 0) return { form: "F1", tokens: [] };
  const all = forms(steps, round);
  for (const each of all)
    if (joined(each[1]).length <= budget) return { form: each[0], tokens: each[1] };
  const last = all[all.length - 1][1][0];
  return { form: "F6", tokens: [token(elide(last.text, budget), last.status)] };
}

// One line of parts ({text, short?, elide?, keep?}) in at most `budget`
// characters, as the text each part shows ("" for a part dropped), in
// order: the short forms first, from the last part back; then the `elide`
// part, down to 4 characters and "…"; then the parts without `keep`, from
// the last back; then the `elide` part further, and last whatever still
// does not fit is cut from the end.
function fit(parts, budget) {
  const texts = parts.map(part => part.text || "");
  const total = () => texts.reduce((sum, text) => sum + text.length, 0);
  for (let i = parts.length - 1; i >= 0 && total() > budget; i--)
    if (typeof parts[i].short === "string") texts[i] = parts[i].short;
  const soft = parts.findIndex(part => part.elide);
  if (soft >= 0 && total() > budget) {
    const room = budget - (total() - texts[soft].length);
    texts[soft] = elide(texts[soft], Math.max(Math.min(5, texts[soft].length), room));
  }
  for (let i = parts.length - 1; i >= 0 && total() > budget; i--)
    if (!parts[i].keep) texts[i] = "";
  if (soft >= 0 && total() > budget)
    texts[soft] = elide(texts[soft], Math.max(0, budget - (total() - texts[soft].length)));
  for (let i = parts.length - 1; i >= 0 && total() > budget; i--)
    texts[i] = elide(texts[i], Math.max(0, budget - (total() - texts[i].length)));
  return texts;
}
