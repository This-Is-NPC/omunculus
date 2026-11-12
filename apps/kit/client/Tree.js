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

// The level of a work: 1 for a root, one more under each work above it;
// L0 is you and the agent that talks with you. `parentOf(item)` is the work
// an item hangs under, or null. One count for every view that says a level.
function levelOf(item, parentOf) {
  let level = 1;
  for (let above = parentOf(item); above; above = parentOf(above)) level++;
  return level;
}

// The level of a node of a Progress build.
function level(node) {
  return node.level + 1;
}

// What stands at L0 above the works, in order: you and, when the works are
// other agents', the agent that talks with you. Nothing without works.
function lead(progress) {
  if (!progress || progress.roots.length === 0) return [];
  const you = { key: "you", kind: "you" };
  return progress.front ? [you, { key: "front", kind: "front", front: progress.front }] : [you];
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

// The rows of the tree, in order. Each is {kind: "front" or "work", key,
// depth, parent (its parent row's key, "" for none), last (the last row
// under its parent), rails (per column left of its elbow, whether a line
// from above goes on down through it), stem (rows show under it)}; a work's
// also has node, kids (the works it handed down that the filters keep) and
// open; the front's front. `opened` maps a work's key to true or false set by
// hand; `keep` (work -> true) shows only the works it holds, every one open.
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
  const front = lead(progress).find(item => item.kind === "front");
  if (front) {
    list.push(Object.assign({}, front, { depth: 0, parent: "", last: true, rails: [], stem: roots.some(keeps) }));
    under("front", roots, 1, []);
  } else {
    under("", roots, 0, []);
  }
  return list;
}

// The works as a chart of level bands, for the TREE page. input: Progress
// build. Returns {cells, links, brackets, columns, levels}. A cell is {key,
// kind ("you", "front" or "work"), node, level (the band: 0 for you and the
// front agent, a work's own depth + 1), col (its column, fractional: a
// parent is centred over its works)}. A link is {from, to: [keys]}, drawn as
// elbows; when the front agent exists, "you" sits beside it in `side`
// ({from, to}). A bracket is {level, from, to (columns), summary} under works
// that ran at once. `columns` and `levels` size the grid.
function chart(progress) {
  const empty = { cells: [], links: [], side: null, brackets: [], columns: 0, levels: 0 };
  if (!progress || progress.roots.length === 0) return empty;
  const cells = [];
  const links = [];
  const brackets = [];
  let next = 0;
  const place = node => {
    const below = kids(node);
    const cell = { key: node.work, kind: "work", node: node, level: level(node), col: 0 };
    cells.push(cell);
    if (below.length === 0) cell.col = next++;
    else {
      const placed = below.map(place);
      cell.col = (placed[0].col + placed[placed.length - 1].col) / 2;
      links.push({ from: node.work, to: below.map(kid => kid.work) });
      plan(below, true).filter(item => item.type === "fork").forEach(item => {
        const ends = item.nodes.map(kid => placed[below.indexOf(kid)].col);
        brackets.push({ level: cell.level + 1, from: ends[0], to: ends[ends.length - 1], summary: summaryOf(item.nodes) });
      });
    }
    return cell;
  };
  const roots = progress.roots.slice().sort((a, b) => a.created - b.created).map(place);
  const centre = (roots[0].col + roots[roots.length - 1].col) / 2;
  const heads = lead(progress).map(item => Object.assign({ node: null, level: 0 }, item));
  const top = heads[heads.length - 1];
  top.col = centre;
  cells.push(top);
  links.push({ from: top.key, to: roots.map(root => root.key) });
  let side = null;
  if (heads.length > 1) {
    heads[0].col = centre - 1;
    cells.push(heads[0]);
    side = { from: "you", to: "front" };
  }
  const shift = Math.min(0, ...cells.map(cell => cell.col));
  cells.forEach(cell => { cell.col -= shift; });
  brackets.forEach(bracket => { bracket.from -= shift; bracket.to -= shift; });
  return {
    cells: cells, links: links, side: side, brackets: brackets,
    columns: Math.max(...cells.map(cell => cell.col)) + 1,
    levels: Math.max(...cells.map(cell => cell.level)) + 1
  };
}

const closedAll = node => Progress.closed(node.state) && Progress.kidsOf(node).every(closedAll);
// When a work's run ended; an open one has not.
const endOf = node => node.state === "up-next" ? -Infinity : node.finishedIn !== null ? node.created + node.finishedIn : Progress.closed(node.state) ? node.created + node.branch.seconds : Infinity;
// The children of a level, as items {type: "work", "fold" or "fork", nodes}:
// works that ran at once and are not all finished are a fork; the finished
// ones that follow one another are one fold.
function plan(nodes, forks) {
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
}

// A fork's summary: "PARALLEL ×4  ·  2 DONE  ·  2 WORKING".
function summaryOf(nodes) {
  const count = state => nodes.filter(node => node.state === state).length;
  const other = nodes.length - count("done") - count("working");
  return ["PARALLEL ×" + nodes.length, count("done") > 0 ? count("done") + " DONE" : "", count("working") > 0 ? count("working") + " WORKING" : "", other > 0 ? other + " OTHER" : ""].filter(part => part !== "").join("  ·  ");
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
// "team" row have id, place and level (of the work that made the request, "L2");
// an "entry" row has thread, index, role, who and `continued`.
// input: {progress, scope (a work, or "" for the whole conversation), opened
// (key -> true or false set by hand), requests, me, counts (work -> entries
// of its thread), lead (the whole conversation as the tree: the "you" and
// "front" rows of L0 come first, with the works one level down, and the
// dialogue is left out), dialogue and details(work) ([{index, at, who, role}] of the
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
    // A request passed up hangs on the work that first asked it.
    const work = Requests.source(request).work_id || "";
    if (place !== "none") (asks[work] = asks[work] || []).push({ request: request, place: place });
  });

  const entriesOf = node => (counts[node.work] || 0) + Progress.kidsOf(node).reduce((sum, kid) => sum + entriesOf(kid), 0);
  const rows = [];
  const dialogueRows = (list, thread, depth, rails, through) => (list || []).map(item => ({
    kind: "entry", key: "entry:" + thread + ":" + item.index, thread: thread, index: item.index, role: item.role, who: item.who, at: item.at,
    depth: depth, rails: rails, through: through, continued: false
  }));
  // The requests a work made, as the rows that hang under it.
  const asksOf = (node, depth, rails, through) => {
    const mine = asks[node ? node.work : ""] || [];
    delete asks[node ? node.work : ""];
    // The work's line runs on to each request's connector, the last one's
    // too unless works go on below it.
    return mine.map((each, nth) => askRow(each, node && byWork[node.work] ? "L" + level(byWork[node.work]) : "", depth, rails, through || nth < mine.length - 1));
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
    // The work's line also goes down to the requests it made.
    const line = through || (asks[node.work] || []).length > 0;
    rows.push({ kind: "work", key: "work:" + node.work, node: node, depth: depth, rails: rails, last: last, kids: kids.length, open: open, stem: line, entries: entriesOf(node) });
    if (node.steps.length > 0) rows.push({ kind: "stages", key: "stages:" + node.work, stages: node.steps, depth: depth + 1, rails: kidRails, through: line });
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
        const summary = summaryOf(item.nodes);
        rows.push({ kind: "fork", key: "fork:" + item.nodes[0].work, nodes: item.nodes, summary: summary, depth: depth, rails: rails, last: last });
        item.nodes.forEach(node => rows.push(...detailsOf(node, depth, rails, !last)));
      } else {
        emitFold(item, depth, rails, last);
      }
    });
  }

  // The blocks of the top level, each with the time its work was made.
  const blocks = [];
  const heads = scope === "" && input.lead ? lead(input.progress) : [];
  const base = heads.length > 0 ? 1 : 0;
  if (scope !== "") {
    if (byWork[scope]) {
      emitWork(byWork[scope], 0, [], true, true);
      blocks.push({ at: 0, rows: rows.splice(0) });
    }
  } else {
    const roots = input.progress ? input.progress.roots.slice().sort((a, b) => a.created - b.created) : [];
    plan(roots, false).forEach(item => {
      if (item.type === "fold") emitFold(item, base, [], true);
      else item.nodes.forEach(node => emitWork(node, base, [], true, false));
      blocks.push({ at: item.nodes[0].created, rows: rows.splice(0) });
    });
  }

  const merged = heads.map(item => Object.assign({ depth: 0, rails: [], last: true, stem: item === heads[heads.length - 1] }, item));
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
