.pragma library
.import "Progress.js" as Progress

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
