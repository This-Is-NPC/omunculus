.pragma library
.import "Progress.js" as Progress

// The TEAM page's tree of agents, from a Progress build: the agent that talks
// with the person at the root when its works are other agents', each work
// under the work that handed it down, every level deep. Which rows show, in
// order, with what the connector lines need; never stored.

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

// The agent a work is known by: its workflow's first, as the surgeon of a
// page its copilot reviews, else its own.
function holder(node) {
  return node.steps.length > 0 ? node.steps[0].agent : node.agent;
}

// The agents of a work's stages, first first, each once, as {agent, status}:
// "current" while one of its stages is, "done" once all of them are, else
// "next"; [] without a workflow.
function stages(node) {
  const agents = Array.from(new Set(node.steps.map(step => step.agent)));
  return agents.map(agent => {
    const own = node.steps.filter(step => step.agent === agent);
    const status = own.some(step => step.status === "current") ? "current" : own.every(step => step.status === "done") ? "done" : "next";
    return { agent: agent, status: status };
  });
}

// Who holds `nodes`, first first, a repeated agent counted: "designer,
// design-reviewer", "surgeon ×3, clerk".
function who(nodes) {
  const counts = new Map();
  for (const node of nodes) counts.set(holder(node), (counts.get(holder(node)) || 0) + 1);
  return Array.from(counts).map(([agent, count]) => count > 1 ? agent + " ×" + count : agent).join(", ");
}

// A fold of several works, keyed by its kind and `key`: {fold, key, nodes, text}.
function fold(kind, key, nodes) {
  const text = kind === "next" ? nodes.length + " up next" : Progress.finished(nodes);
  return { fold: kind, key: kind + ":" + key, nodes: nodes, text: text + " · " + who(nodes) };
}

// The works handed down under the parent keyed `at`, as the tree shows them:
// each a node, or a fold of several. While any of them is open, the done and
// cancelled ones fold into one line, and so do those up next, two or more
// each; once all are closed, the three or more of one holder fold into one
// line, at the place of its first.
function groups(at, kids) {
  const closed = kids.filter(kid => Progress.closed(kid.state));
  const single = node => ({ node: node });
  if (closed.length < kids.length) {
    const next = kids.filter(kid => kid.state === "up-next");
    const going = kids.filter(kid => !Progress.closed(kid.state) && kid.state !== "up-next");
    return (closed.length >= 2 ? [fold("done", at, closed)] : closed.map(single))
      .concat(going.map(single), next.length >= 2 ? [fold("next", at, next)] : next.map(single));
  }
  const out = [];
  for (const kid of kids) {
    const same = kids.filter(each => holder(each) === holder(kid));
    if (same.length < 3) out.push(single(kid));
    else if (same[0] === kid) out.push(fold("done", at + ":" + holder(kid), same));
  }
  return out;
}

// Whether a work shows the works it handed down before the person says: when
// one of them is still open, or it is a root.
function opensAlone(node) {
  return node.parent === "" || Progress.kidsOf(node).some(kid => !Progress.closed(kid.state));
}

// The rows of the tree, in order. Each is {kind: "front", "work" or "fold",
// key, depth, parent (its parent row's key, "" for none), last (the last row
// under its parent), rails (per column left of its elbow, whether a line
// from above goes on down through it), stem (rows show under it)}; a work's
// also has node, kids (the works it handed down that the filters keep) and
// open; a fold's fold ("done" or "next"), text, count and folded; the
// front's front. `opened` maps a row's key to true or false set by hand;
// `keep`, from kept(), shows only the works it keeps, every one open.
function rows(progress, opened, keep) {
  if (!progress) return [];
  const list = [];
  const keeps = node => keep === null || !!keep[node.work];
  const isOpen = (key, alone) => keep !== null ? true : opened[key] !== undefined ? !!opened[key] : alone;
  // The rows under the parent keyed `at`, at `depth`, `rails` the columns
  // left of their elbow.
  const under = (at, kids, depth, rails) => {
    const shown = kids.filter(keeps);
    const entries = [];
    for (const group of keep !== null ? shown.map(node => ({ node: node })) : groups(at, shown)) {
      if (!group.fold) {
        entries.push({ node: group.node });
        continue;
      }
      const folded = !isOpen(group.key, group.nodes.some(node => node.below !== ""));
      entries.push({ fold: group, folded: folded });
      if (!folded) group.nodes.forEach(node => entries.push({ node: node }));
    }
    entries.forEach((entry, i) => {
      const last = i === entries.length - 1;
      const row = { depth: depth, parent: at, last: last, rails: rails, stem: false };
      if (entry.fold) {
        list.push(Object.assign(row, {
          kind: "fold", key: entry.fold.key, fold: entry.fold.fold, text: entry.fold.text,
          count: entry.fold.nodes.length, folded: entry.folded
        }));
        return;
      }
      const node = entry.node;
      const kids = Progress.kidsOf(node).filter(keeps);
      const open = kids.length > 0 && isOpen(node.work, opensAlone(node));
      list.push(Object.assign(row, { kind: "work", key: node.work, node: node, kids: kids.length, open: open, stem: open }));
      if (open) under(node.work, kids, depth + 1, depth > 0 ? rails.concat([!last]) : []);
    });
  };
  if (progress.front) {
    list.push({ kind: "front", key: "front", depth: 0, parent: "", last: true, rails: [], stem: progress.roots.some(keeps), front: progress.front });
    under("front", progress.roots, 1, []);
  } else {
    under("", progress.roots, 0, []);
  }
  return list;
}

// `opened` with what makes `work` show opened: the works above it and the
// fold it or one above it is in; the same object when nothing changes.
function reveal(progress, opened, work) {
  const byWork = index(progress ? progress.flat : []);
  const keys = [];
  for (let at = byWork[work]; at; at = byWork[at.parent]) {
    const parent = byWork[at.parent] || null;
    if (parent) keys.push(parent.work);
    const key = parent ? parent.work : progress.front ? "front" : "";
    const group = groups(key, parent ? Progress.kidsOf(parent) : progress.roots).find(each => each.fold && each.nodes.includes(at));
    if (group) keys.push(group.key);
  }
  const shut = keys.filter(key => opened[key] !== true);
  if (shut.length === 0) return opened;
  const next = Object.assign({}, opened);
  shut.forEach(key => { next[key] = true; });
  return next;
}

// What a key does on the row at `at`: {at} the row to move to, or {toggle,
// open} a work or fold to open or close. ↑/↓ move to the row before or
// after, past the front; → opens a closed work or fold, else goes to the
// first row under it; ← closes an open one, else goes to its parent's row.
// null for nothing.
function step(list, at, key) {
  const row = list[at];
  if (!row) return null;
  const by = key === "up" ? -1 : key === "down" ? 1 : 0;
  if (by !== 0) {
    let to = at + by;
    while (to >= 0 && to < list.length && list[to].kind === "front") to += by;
    return to >= 0 && to < list.length ? { at: to } : null;
  }
  const shut = row.kind === "fold" ? row.folded : row.kind === "work" && row.kids > 0 && !row.open;
  const opens = row.kind === "fold" ? !row.folded : row.kind === "work" && row.open;
  if (key === "right") {
    if (shut) return { toggle: row.key, open: true };
    return opens && at + 1 < list.length ? { at: at + 1 } : null;
  }
  if (key === "left") {
    if (opens) return { toggle: row.key, open: false };
    const parent = list.findIndex(each => each.key === row.parent);
    return parent >= 0 && list[parent].kind !== "front" ? { at: parent } : null;
  }
  return null;
}
