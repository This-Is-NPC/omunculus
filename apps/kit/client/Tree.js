.pragma library
.import "Progress.js" as Progress
.import "Pending.js" as Pending
.import "Requests.js" as Requests

// The TREE page's works, from a Progress build: the agent that talks with the
// person at the root when its works are other agents', each work under the
// work that handed it down, every level deep, in the order they were made.
// Which rows show, in order, with what the connector lines need; never stored.

function index(flat) {
  const byWork = {};
  for (const node of flat) byWork[node.work] = node;
  return byWork;
}

// The works the filters keep — those of the chip's state ("all", or a state)
// whose title, agent or stage hold every word of `filter` — and every work
// above one, as work id -> true; null while nothing filters.
function kept(flat, chip, filter) {
  const words = String(filter || "").toLowerCase().split(/\s+/).filter(word => word);
  if (chip === "all" && words.length === 0) return null;
  const byWork = index(flat);
  const keep = {};
  for (const node of flat) {
    const text = [node.title, node.agent].concat(node.steps.map(step => step.name)).join(" ").toLowerCase();
    if ((chip === "all" || node.state === chip) && words.every(word => text.includes(word)))
      for (let at = node; at && !keep[at.work]; at = byWork[at.parent]) keep[at.work] = true;
  }
  return keep;
}

// The works a node handed down, in the order they were made.
function kids(node) {
  return Progress.kidsOf(node).slice().sort((a, b) => a.created - b.created);
}

// Whether a work shows the works it handed down before the person says: when
// one of them is still open, or it is a root.
function opensAlone(node) {
  return node.parent === "" || Progress.kidsOf(node).some(kid => !Progress.closed(kid.state));
}

// What a work's state reads in the tree, as {state, text}: its own word, a
// work waiting on a child or an agent says whom, "WAITING FOR YOU" when it or
// the question it passed up waits on the person, "WORKING · ROUND 3" once it
// was sent back.
function stateOf(node) {
  if (node.state === "needs-you" || (node.state === "waiting" && node.waitingOn === "you"))
    return { state: "needs-you", text: "WAITING FOR YOU" };
  if (node.state === "waiting")
    return { state: "waiting", text: "WAITING FOR " + (node.waitingOn || "the team").toUpperCase() };
  const words = { working: "WORKING", done: "DONE", failed: "FAILED", cancelled: "CANCELLED", stopped: "STOPPED", "up-next": "UP NEXT" };
  return { state: node.state, text: (words[node.state] || "") + (node.state === "working" && node.round > 1 ? " · ROUND " + node.round : "") };
}

// The same for the agent that talks with the person (Progress `front`).
function frontState(front) {
  if (front.state === "working") return { state: "working", text: "WORKING" };
  if (front.state === "needs-you") return { state: "needs-you", text: "WAITING FOR YOU" };
  if (front.state === "waiting") return { state: "waiting", text: front.doing.replace(/^Waiting for /, "WAITING FOR ").toUpperCase() };
  return { state: "idle", text: "IDLE" };
}

// How long a work has run, in seconds: the time it took once done, its
// branch's once closed, else since it was made.
function elapsed(node, now) {
  if (node.finishedIn !== null) return node.finishedIn;
  return Progress.closed(node.state) ? node.branch.seconds : Math.max(0, now - node.created);
}

// How long the conversation has run, in seconds: since its first work was
// made, while any is open, else until the last one's branch ended.
function frontElapsed(progress, now) {
  const roots = progress ? progress.roots : [];
  if (roots.length === 0) return 0;
  const first = Math.min(...roots.map(root => root.created));
  const end = roots.some(root => !Progress.closed(root.state)) ? now : Math.max(...roots.map(root => root.created + root.branch.seconds));
  return Math.max(0, end - first);
}

// The rows of the tree, in order. Each is {kind: "front" or "work", key,
// depth, parent (its parent row's key, "" for none), last (the last row
// under its parent), rails (per column left of its elbow, whether a line
// from above goes on down through it), stem (rows show under it)}; a work's
// also has node, kids (the works it handed down that the filters keep) and
// open; the front's front. `opened` maps a work's key to true or false set by
// hand; `keep`, from kept(), shows only the works it keeps, every one open.
function rows(progress, opened, keep) {
  if (!progress) return [];
  const list = [];
  const keeps = node => keep === null || !!keep[node.work];
  const isOpen = (key, alone) => keep !== null ? true : opened[key] !== undefined ? !!opened[key] : alone;
  const under = (at, nodes, depth, rails) => {
    const shown = nodes.filter(keeps);
    shown.forEach((node, i) => {
      const last = i === shown.length - 1;
      const below = kids(node).filter(keeps);
      const open = below.length > 0 && isOpen(node.work, opensAlone(node));
      list.push({ kind: "work", key: node.work, node: node, depth: depth, parent: at, last: last, rails: rails, kids: below.length, open: open, stem: open });
      if (open) under(node.work, below, depth + 1, depth > 0 ? rails.concat([!last]) : []);
    });
  };
  const roots = progress.roots.slice().sort((a, b) => a.created - b.created);
  if (progress.front) {
    list.push({ kind: "front", key: "front", depth: 0, parent: "", last: true, rails: [], stem: roots.some(keeps), front: progress.front });
    under("front", roots, 1, []);
  } else {
    under("", roots, 0, []);
  }
  return list;
}

// `opened` with what makes `work` show opened: the works above it; the same
// object when nothing changes.
function reveal(progress, opened, work) {
  const byWork = index(progress ? progress.flat : []);
  const shut = [];
  for (let at = byWork[work]; at; at = byWork[at.parent])
    if (at.parent && opened[at.parent] !== true) shut.push(at.parent);
  if (shut.length === 0) return opened;
  const next = Object.assign({}, opened);
  shut.forEach(key => { next[key] = true; });
  return next;
}

// What a key does on the row at `at`: {at} the row to move to, or {toggle,
// open} a work to open or close. ↑/↓ move to the row before or after, past
// the front; → opens a closed work, else goes to the first row under it; ←
// closes an open one, else goes to its parent's row. null for nothing.
function step(list, at, key) {
  const row = list[at];
  if (!row) return null;
  const by = key === "up" ? -1 : key === "down" ? 1 : 0;
  if (by !== 0) {
    let to = at + by;
    while (to >= 0 && to < list.length && list[to].kind === "front") to += by;
    return to >= 0 && to < list.length ? { at: to } : null;
  }
  const shut = row.kind === "work" && row.kids > 0 && !row.open;
  if (key === "right") {
    if (shut) return { toggle: row.key, open: true };
    return row.open && at + 1 < list.length ? { at: at + 1 } : null;
  }
  if (key === "left") {
    if (row.open) return { toggle: row.key, open: false };
    const parent = list.findIndex(each => each.key === row.parent);
    return parent >= 0 && list[parent].kind !== "front" ? { at: parent } : null;
  }
  return null;
}

// The conversation as a lineage stream, the rows of the chat: the person's
// and the front agent's words in time order and, among them, each work as a
// level of the hierarchy, in the same geometry as `rows`. A work shows as a
// "work" row with, under it, its "stages" path, the requests it made ("ask"
// for one to you, "team" for one between agents) and, in a scope, the
// "entry" rows of its own thread; the works it handed down come after, each a
// "work" row, a "fold" (finished works gathered in one line) or a "fork"
// (works that ran at once, as lane cards). Every row has `key` (unique and
// stable), `kind`, `depth` (the column of its mark; 0 for a root), `rails`
// (as in `rows`) and, for what hangs under a work, `through` (the work's
// line goes on past it). A work, fold and fork also have `last` (the last
// child of its parent). A "work" row has node, kids (how many works it
// handed down), open (they show) and stem (rows of its own hang under it); a
// "fold" has nodes, entries (their count, with the works below) and
// `unfolded` (set by hand: each work follows the fold's line, to fold again); a "fork" has nodes,
// summary ("PARALLEL ×4 · 2 DONE · 2 WORKING") and lanes; an "ask" and a
// "team" row have id, place and level (the arbiter's level, "L0" for you);
// an "entry" row has thread, index, role, who and `continued`.
// input: {progress, scope (a work, or "" for the whole conversation), opened
// (key -> true or false set by hand), requests, me, counts (work -> entries
// of its thread), dialogue and details(work) ([{index, at, who, role}] of the
// main thread, and of a work's in a scope)}.
function stream(input) {
  const flat = input.progress ? input.progress.flat : [];
  const byWork = index(flat);
  const opened = input.opened || {};
  const counts = input.counts || {};
  const requests = input.requests || [];
  const hidden = Requests.contained(requests);
  const scope = input.scope || "";
  const asks = {};
  requests.slice().sort((a, b) => String(a.created_at || "").localeCompare(String(b.created_at || ""))).forEach(request => {
    const place = Pending.place(request, { me: input.me, contained: hidden });
    if (place !== "none") (asks[request.work_id || ""] = asks[request.work_id || ""] || []).push({ request: request, place: place });
  });

  const closedAll = node => Progress.closed(node.state) && Progress.kidsOf(node).every(closedAll);
  const entriesOf = node => (counts[node.work] || 0) + Progress.kidsOf(node).reduce((sum, kid) => sum + entriesOf(kid), 0);
  // When a work's run ended; an open one has not.
  const endOf = node => node.state === "up-next" ? -Infinity : node.finishedIn !== null ? node.created + node.finishedIn : Progress.closed(node.state) ? node.created + node.branch.seconds : Infinity;
  // The level a request is decided at: "L0" for you, else its arbiter's work.
  const levelOf = (request, node) => {
    if (Requests.forYou(request, input.me)) return "L0";
    const arbiter = Requests.label(request.arbiter);
    for (let at = node; at; at = byWork[at.parent]) if (at.agent === arbiter) return "L" + (at.level + 1);
    return "";
  };

  // The children of a level, as items {type: "work", "fold" or "fork", nodes}:
  // works that ran at once and are not all finished are a fork; the finished
  // ones that follow one another are one fold.
  const plan = (nodes, forks) => {
    const groups = [];
    for (const node of nodes) {
      const last = groups[groups.length - 1];
      if (forks && last && node.state !== "up-next" && node.created < last.end) {
        last.nodes.push(node);
        last.end = Math.max(last.end, endOf(node));
      } else groups.push({ nodes: [node], end: endOf(node) });
    }
    const items = [];
    for (const group of groups) {
      if (group.nodes.length > 1 && !group.nodes.every(closedAll)) items.push({ type: "fork", nodes: group.nodes });
      else for (const node of group.nodes) {
        const before = items[items.length - 1];
        if (!closedAll(node)) items.push({ type: "work", nodes: [node] });
        else if (before && before.type === "fold") before.nodes.push(node);
        else items.push({ type: "fold", nodes: [node] });
      }
    }
    return items;
  };

  const rows = [];
  const dialogueRows = (list, thread, depth, rails, through) => (list || []).map(item => ({
    kind: "entry", key: "entry:" + thread + ":" + item.index, thread: thread, index: item.index, role: item.role, who: item.who, at: item.at,
    depth: depth, rails: rails, through: through, continued: false
  }));
  // The requests a work made, as the rows that hang under it.
  const asksOf = (node, depth, rails, through) => {
    const mine = asks[node ? node.work : ""] || [];
    delete asks[node ? node.work : ""];
    return mine.map(each => askRow(each, levelOf(each.request, node), depth, rails, through));
  };
  function askRow(each, level, depth, rails, through) {
    return {
      kind: each.place === "team" ? "team" : "ask", key: "ask:" + each.request.id, id: each.request.id, place: each.place,
      level: level, depth: depth, rails: rails, through: through
    };
  }
  const detailsOf = (node, depth, rails, through) => scope !== "" && input.details ? dialogueRows(input.details(node.work), node.work, depth, rails, through) : [];

  const emitWork = (node, depth, rails, last, force) => {
    const kids = Progress.kidsOf(node).slice().sort((a, b) => a.created - b.created);
    const open = kids.length > 0 && (force || (opened[node.work] !== undefined ? !!opened[node.work] : opensAlone(node)));
    const items = open ? plan(kids, true) : [];
    const kidRails = depth > 0 ? rails.concat([!last]) : [];
    const through = items.length > 0;
    rows.push({ kind: "work", key: "work:" + node.work, node: node, depth: depth, rails: rails, last: last, kids: kids.length, open: open, stem: through, entries: entriesOf(node) });
    if (node.steps.length > 0) rows.push({ kind: "stages", key: "stages:" + node.work, stages: node.steps, depth: depth + 1, rails: kidRails, through: through });
    rows.push(...asksOf(node, depth + 1, kidRails, through), ...detailsOf(node, depth + 1, kidRails, through));
    emitItems(items, depth + 1, kidRails);
  };

  // A fold unfolded by hand stays as the line above its works, to fold again.
  const emitFold = (item, depth, rails, last) => {
    const key = "fold:" + item.nodes[0].work;
    const unfolded = !!opened[key];
    const kidRails = depth > 0 ? rails.concat([!last]) : [];
    rows.push({ kind: "fold", key: key, nodes: item.nodes, entries: item.nodes.reduce((sum, node) => sum + entriesOf(node), 0), depth: depth, rails: rails, last: last && !unfolded, unfolded: unfolded });
    if (unfolded) item.nodes.forEach((node, nth) => emitWork(node, depth, rails, last && nth === item.nodes.length - 1, false));
    else item.nodes.forEach(node => rows.push(...asksOf(node, depth + 1, kidRails, false)));
  };

  function emitItems(items, depth, rails) {
    items.forEach((item, at) => {
      const last = at === items.length - 1;
      if (item.type === "work") {
        emitWork(item.nodes[0], depth, rails, last, false);
      } else if (item.type === "fork") {
        const count = state => item.nodes.filter(node => node.state === state).length;
        const other = item.nodes.length - count("done") - count("working");
        const summary = ["PARALLEL ×" + item.nodes.length, count("done") > 0 ? count("done") + " DONE" : "", count("working") > 0 ? count("working") + " WORKING" : "", other > 0 ? other + " OTHER" : ""].filter(part => part !== "").join("  ·  ");
        rows.push({ kind: "fork", key: "fork:" + item.nodes[0].work, nodes: item.nodes, summary: summary, depth: depth, rails: rails, last: last });
        item.nodes.forEach(node => rows.push(...detailsOf(node, depth, rails, !last)));
      } else {
        emitFold(item, depth, rails, last);
      }
    });
  }

  // The blocks of the top level, each with the time its work was made.
  const blocks = [];
  if (scope !== "") {
    if (byWork[scope]) {
      emitWork(byWork[scope], 0, [], true, true);
      blocks.push({ at: 0, rows: rows.splice(0) });
    }
  } else {
    const roots = input.progress ? input.progress.roots.slice().sort((a, b) => a.created - b.created) : [];
    plan(roots, false).forEach(item => {
      if (item.type === "fold") emitFold(item, 0, [], true);
      else item.nodes.forEach(node => emitWork(node, 0, [], true, false));
      blocks.push({ at: item.nodes[0].created, rows: rows.splice(0) });
    });
  }

  const merged = [];
  if (scope === "") {
    const words = (input.dialogue || []).slice();
    for (const block of blocks) {
      while (words.length > 0 && words[0].at < block.at) merged.push(...dialogueRows([words.shift()], "", 0, [], false));
      merged.push(...block.rows);
    }
    merged.push(...dialogueRows(words, "", 0, [], false));
    // The requests of a work the tree does not know.
    Object.keys(asks).forEach(work => merged.push(...asksOf({ work: work }, 0, [], false)));
  } else blocks.forEach(block => merged.push(...block.rows));

  // A speaker's next line right after its own, with no work between and no
  // long pause, drops its heading.
  merged.forEach((row, at) => {
    const before = merged[at - 1];
    row.continued = row.kind === "entry" && !!before && before.kind === "entry" && before.thread === row.thread
      && before.who === row.who && row.at - before.at < (input.pause || 120) && !["note"].includes(row.role) && !["note"].includes(before.role);
  });
  return merged;
}
