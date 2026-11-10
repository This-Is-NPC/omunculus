.pragma library
.import "Requests.js" as Requests
.import "Questions.js" as Questions

// The projects of a server's registry and their conversations as the start,
// the projects page and the conversations page list them, from what was read
// of each project: its conversations, its works and each conversation's
// summary. Every count of conversations comes from `state`, so the pages
// agree.

// A conversation as its snapshot says it, for its line in the lists:
//   title: what was first said in it, on one line; agent: whom it is with,
//   the agent of its first run at depth 0, "" before one; started;
//   finished: every work of it is done or cancelled; running: its runs open;
//   waiting: the requests waiting on you; asks: those by kind, {questions,
//   decisions, permissions, owner, client}, `owner` and `client` counting
//   those for the owner and for the client, a numbered question counted by its items;
//   since: when the oldest of them was asked, "" for none; question: what the
//   newest asks, on one line; failed: nothing runs and the last run `ended`
//   in an error, which only the events tell: its text, "" for none.
function summary(data, ended) {
  const said = data.prompts.find(prompt => prompt.kind === "message");
  const first = data.runs.filter(run => String(run.depth) === "0" && run.agent)
    .sort((a, b) => String(a.started_at || "").localeCompare(String(b.started_at || "")))[0];
  const waiting = data.requests.filter(request => Requests.pending(request) && Requests.human(request.arbiter))
    .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
  const asks = { questions: 0, decisions: 0, permissions: 0, owner: 0, client: 0 };
  for (const request of waiting) {
    asks[Requests.audience(request)] += 1;
    const kind = Requests.kind(request);
    if (kind === "permission") asks.permissions += 1;
    else if (kind === "decision") asks.decisions += 1;
    else {
      const form = Questions.parse(Requests.question(request, true));
      asks.questions += form ? form.items.length : 1;
    }
  }
  const newest = waiting[waiting.length - 1];
  return {
    title: said ? String(said.body).replace(/\s+/g, " ") : "",
    agent: first ? first.agent : "",
    started: data.prompts.length > 0,
    finished: data.works.length > 0 && data.works.every(work => work.state === "done" || work.state === "cancelled"),
    running: data.runs.filter(run => run.status === "open").length,
    failed: !!ended && data.runs.every(run => run.status !== "open"),
    waiting: waiting.length,
    asks: asks,
    since: waiting.length > 0 ? waiting[0].created_at : "",
    question: newest ? Requests.question(newest, true).replace(/\s+/g, " ").trim() : ""
  };
}

// The last error a run of a conversation ended in, from its events, "" when
// the last run to end did not fail.
function ended(events) {
  const last = events.filter(event => event.type === "end-run").pop();
  return last && last.body && last.body.error ? String(last.body.error) : "";
}

// Whether the events tell more about a conversation: nothing runs, waits on
// you or is over, so it may have failed.
function unsettled(summary) {
  return summary.started && !summary.finished && summary.running === 0 && summary.waiting === 0;
}

// The state of a conversation from its summary, null while it is not read:
// "not-started", "needs-you" while something waits on you, "working" while
// agents run in it, "done" once its works are, "failed" when the last run
// ended in an error, else "idle"; "" unread.
function state(summary) {
  if (!summary) return "";
  return !summary.started ? "not-started"
    : summary.waiting > 0 ? "needs-you"
    : summary.running > 0 ? "working"
    : summary.finished ? "done"
    : summary.failed ? "failed"
    : "idle";
}

// What waits on you in a conversation, from its summary's `asks`, as its
// state says it: whom it is for, then its kinds: "OWNER DECISION · A
// PERMISSION · 2 DECISIONS · 7 QUESTIONS".
function waitsFor(asks) {
  const say = (count, one, many) => count === 0 ? [] : [count === 1 ? one : count + " " + many];
  return [].concat(
    asks.owner > 0 ? [Requests.audiences.owner.text] : [],
    asks.client > 0 ? [Requests.audiences.client.text] : [],
    say(asks.permissions, "A PERMISSION", "PERMISSIONS"),
    say(asks.decisions, "A DECISION", "DECISIONS"),
    say(asks.questions, "A QUESTION", "QUESTIONS")
  ).join(" · ");
}

// One row per project of `input`:
//   {projects: [{id, socket}], conversations: project id -> [conversation],
//    works: project id -> [work], summaries: conversation id -> summary,
//    unreachable: Set of project ids, current: the window's project id}
// `needsYou`, `working` and `failed` count its conversations in those states; a
// project whose socket did not answer counts none: what was read of it may
// be stale. One whose conversations, or any summary of them, are not read
// yet is "reading" and counts none: a partial count would be a wrong one.
function rows(input) {
  return input.projects.map(place => {
    const conversations = input.conversations[place.id];
    const works = input.works[place.id] || [];
    const reachable = !input.unreachable.has(place.id);
    const states = (conversations || []).map(conversation => state(input.summaries[conversation.id] || null));
    const reading = reachable && (conversations === undefined || states.includes(""));
    const count = wanted => reachable && !reading ? states.filter(each => each === wanted).length : 0;
    const needsYou = count("needs-you");
    const working = count("working");
    const failed = count("failed");
    const stamps = (conversations || []).map(conversation => conversation.created_at)
      .concat(works.map(work => work.updated_at))
      .filter(stamp => stamp);
    return {
      id: place.id,
      socket: place.socket,
      current: place.id === input.current,
      reachable: reachable,
      conversations: (conversations || []).length,
      needsYou: needsYou,
      working: working,
      failed: failed,
      last: stamps.reduce((newest, stamp) => stamp > newest ? stamp : newest, ""),
      state: !reachable ? "unreachable"
        : reading ? "reading"
        : needsYou > 0 ? "waiting"
        : working > 0 ? "working"
        : failed > 0 ? "failed"
        : "idle"
    };
  });
}

// Most conversations needing you first, then most working, then most failed,
// then the latest activity, then the id.
function sort(rows) {
  return rows.slice().sort((a, b) => b.needsYou - a.needsYou || b.working - a.working || b.failed - a.failed
    || (a.last < b.last ? 1 : a.last > b.last ? -1 : 0)
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

// The rows in the state `chip` ("" for all, "waiting" or "working") whose id
// holds every word of `text`.
function filter(rows, text, chip) {
  const words = String(text).toLowerCase().split(/\s+/).filter(word => word);
  return rows.filter(row => (chip === "" || row.state === chip)
    && words.every(word => row.id.toLowerCase().includes(word)));
}

// Whether any project of `rows` is still being read.
function reading(rows) {
  return rows.some(row => row.state === "reading");
}

// The conversations needing you in the projects the window is not on, none
// while one of them is still being read.
function elsewhere(rows) {
  const others = rows.filter(row => !row.current);
  return reading(others) ? 0 : others.reduce((sum, row) => sum + row.needsYou, 0);
}

// A project's line under its id in at most `budget` characters, its parts
// joined by `separator`: "15 conversations · 12 need you · 1 working ·
// Yesterday 22:43", `last` its last activity. What does not fit goes first:
// the working, then the last activity, then the conversations shorten to
// "15 conv."; what needs you stays. Parts with nothing to count are left
// out.
function meta(row, last, budget, separator) {
  const named = row.conversations + (row.conversations === 1 ? " conversation" : " conversations");
  const needs = row.needsYou > 0 ? [row.needsYou + (row.needsYou === 1 ? " needs you" : " need you")] : [];
  const working = row.working > 0 ? [row.working + " working"] : [];
  const failed = row.failed > 0 ? [row.failed + " failed"] : [];
  const stamp = last ? [last] : [];
  const candidates = [
    [named].concat(needs, working, failed, stamp),
    [named].concat(needs, failed, stamp),
    [named].concat(needs, failed),
    [row.conversations + " conv."].concat(needs, failed)
  ].map(parts => parts.join(separator));
  return candidates.find(text => text.length <= budget) || candidates[candidates.length - 1];
}
