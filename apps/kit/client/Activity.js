.pragma library
.import "Requests.js" as Requests
.import "Phrases.js" as Phrases

const none = { name: "", index: 0, count: 0, next: "" };

function upper(text) { return String(text || "").toUpperCase(); }

// What the conversation's team is doing now, derived and never stored.
// input: {runs: [{id, agent, depth, work_id, status, error?}], works, requests,
// lanes (work id -> {name, steps: [{name, agent}], at} or null), calling (work
// id -> last tool), callArgs (work id -> that call's args), runStarts (run id -> seconds), now (seconds)}.
// Returns {state, headline, since, stage: {name, index, count, next},
// rows: [{work, agent, depth, state, task, phrase, since, parent}], loop}.
function status(input) {
  const runs = input.runs || [];
  const works = input.works || [];
  const lanes = input.lanes || {};
  const calling = input.calling || {};
  const callArgs = input.callArgs || {};
  const starts = input.runStarts || {};
  const open = runs.filter(run => run.status === "open");
  const asking = (input.requests || []).filter(Requests.pending);
  const forYou = asking.filter(request => Requests.human(request.arbiter));
  const forTeam = asking.filter(request => !Requests.human(request.arbiter));

  const rows = tree(works).map(entry => row(entry, open, asking, lanes, calling, callArgs, starts));
  const stage = stageOf(works, lanes);
  const focus = open.slice().sort((a, b) => (a.depth || 0) - (b.depth || 0)).pop() || null;
  const lastRun = runs[runs.length - 1];
  const failedRun = lastRun && lastRun.status !== "open" && lastRun.error ? lastRun : null;

  let state = "idle";
  let headline = "";
  let since = null;
  if (forYou.length > 0) {
    state = "waiting-you";
    headline = upper(Requests.label(forYou[0].requester)) + " IS WAITING FOR YOUR ANSWER";
  } else if (focus) {
    state = "working";
    const call = calling[focus.work_id || ""];
    const doing = call ? upper(focus.agent) + ": " + upper(Phrases.phrase(call, callArgs[focus.work_id || ""])) : upper(focus.agent) + " IS GETTING STARTED";
    headline = [subject(works), doing].concat(stage.count > 0 ? ["STEP " + stage.index + " OF " + stage.count + ": " + upper(stage.name)] : []).join("  -  ");
    since = starts[focus.id] === undefined ? null : starts[focus.id];
  } else if (forTeam.length > 0) {
    state = "waiting-team";
    headline = upper(Requests.label(forTeam[0].requester)) + " IS WAITING FOR " + upper(Requests.label(forTeam[0].arbiter));
  } else if (works.some(isBroken) || failedRun) {
    state = "failed";
    const why = failedRun ? String(failedRun.error).split("\n")[0].slice(0, 80) : "a step broke";
    headline = "THE TEAM STOPPED: " + why + "  -  See the log";
  } else if (works.some(work => work.state === "done") && works.every(work => ["done", "cancelled"].includes(work.state))) {
    state = "done";
    headline = "DELIVERED";
  }
  return { state: state, headline: headline, since: since, stage: stage, rows: rows, loop: loopOf(runs) };
}

// What the team works on: the first root work's title, cut at 40 characters,
// or "YOUR REQUEST" before any work exists.
function subject(works) {
  const root = works.find(work => !work.parent_id && work.title);
  if (!root) return "YOUR REQUEST";
  const title = upper(root.title);
  return title.length > 40 ? title.slice(0, 39) + "…" : title;
}

// A work waiting on nothing: it broke, and its parent decides.
function isBroken(work) {
  return work.state === "broken" || (work.state === "waiting" && !work.waiting);
}

function tree(works) {
  const ordered = [];
  const visit = (parent, level) => works.filter(work => (work.parent_id || "") === parent)
    .forEach(work => { ordered.push({ work: work, level: level }); visit(work.id, level + 1); });
  visit("", 0);
  return ordered;
}

function row(entry, open, asking, lanes, calling, callArgs, starts) {
  const work = entry.work;
  const lane = lanes[work.id] || null;
  const run = open.find(each => (each.work_id || "") === work.id) || null;
  const mine = asking.filter(request => (request.work_id || "") === work.id);
  let state = "idle";
  if (run) state = "working";
  else if (mine.some(request => Requests.human(request.arbiter))) state = "waiting-you";
  else if (mine.length > 0 || (work.state === "waiting" && work.waiting === "child")) state = "waiting-team";
  else if (isBroken(work)) state = "failed";
  else if (work.state === "done") state = "done";
  return {
    work: work.id,
    agent: run ? run.agent : lane ? lane.steps[lane.at].agent : work.assignee || "",
    depth: entry.level,
    state: state,
    task: work.title || "",
    phrase: run ? Phrases.phrase(calling[work.id] || "", callArgs[work.id]) : "",
    since: run && starts[run.id] !== undefined ? starts[run.id] : null,
    parent: work.parent_id || ""
  };
}

// The first root work in a workflow: its step among the steps, from the stage
// transitions rather than anything an agent said.
function stageOf(works, lanes) {
  const root = works.find(work => !work.parent_id && lanes[work.id]);
  if (!root) return none;
  const lane = lanes[root.id];
  const next = lane.steps[lane.at + 1];
  return { name: lane.steps[lane.at].name, index: lane.at + 1, count: lane.steps.length, next: next ? next.name : "" };
}

// When the latest run returns a work to an agent that already ran on it, after
// another agent's run: "REVIEWER SENT IT BACK TO DESIGNER, ROUND 2".
function loopOf(runs) {
  const last = runs[runs.length - 1];
  if (!last) return "";
  const same = runs.filter(run => (run.work_id || "") === (last.work_id || ""));
  const before = same[same.length - 2];
  const rounds = same.filter(run => run.agent === last.agent).length;
  return before && before.agent !== last.agent && rounds > 1
    ? upper(before.agent) + " SENT IT BACK TO " + upper(last.agent) + ", ROUND " + rounds : "";
}
