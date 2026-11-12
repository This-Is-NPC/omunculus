.pragma library
.import "Tree.js" as Tree

// The log's lines in the order a grouping shows them, as items for the list:
// {kind: "line", line, col, rails, through} for an event, with the headers
// {kind: "level", level, text} and {kind: "work", row, count} (a Tree.rows
// row, so a work heads its lines in the geometry of the tree). `col` is the
// column of a line's mark, -1 for none; `rails` and `through` are the
// lifeline's, as in Tree.stream. `by`: "level", "work" or "time" (as given).
// A level is the work's level in the hierarchy (Tree.level); L0 is you and the
// agent that talks with you.

function line(line, col, rails, through) {
  return { kind: "line", line: line, col: col, rails: rails, through: through };
}

function plural(count) { return count + (count === 1 ? " event" : " events"); }

function byLevel(lines, progress) {
  const byWork = Tree.index(progress ? progress.flat : []);
  const levels = {};
  for (const each of lines) {
    const node = byWork[each.work];
    const level = node ? Tree.level(node) : 0;
    (levels[level] = levels[level] || []).push(each);
  }
  const items = [];
  Object.keys(levels).map(Number).sort((a, b) => a - b).forEach(level => {
    const agents = Array.from(new Set(levels[level].map(each => each.who).filter(who => who !== "" && who !== "harness")));
    items.push({ kind: "level", level: level, text: ["LEVEL " + level].concat(agents.length > 0 ? [agents.join(", ")] : [], [plural(levels[level].length)]).join("  ·  ") });
    levels[level].forEach(each => items.push(line(each, level, [], false)));
  });
  return items;
}

function byWork(lines, progress) {
  const flat = progress ? progress.flat : [];
  const opened = {};
  flat.forEach(node => { opened[node.work] = true; });
  const rows = Tree.rows(progress, opened, null);
  const known = {};
  rows.forEach(row => { if (row.kind === "work") known[row.key] = true; });
  const mine = {};
  // Lines of no work known to the tree go under the front agent, else first.
  const loose = [];
  for (const each of lines) {
    if (known[each.work]) (mine[each.work] = mine[each.work] || []).push(each);
    else loose.push(each);
  }
  const items = [];
  rows.forEach((row, at) => {
    const own = row.kind === "front" ? loose : mine[row.key] || [];
    items.push({ kind: "work", row: row, count: own.length });
    const rails = row.depth > 0 ? row.rails.concat([!row.last]) : [];
    own.forEach(each => items.push(line(each, row.depth + 1, rails, row.stem)));
  });
  if (!rows.some(row => row.kind === "front") && loose.length > 0)
    return [{ kind: "level", level: 0, text: "NO WORK  ·  " + plural(loose.length) }].concat(loose.map(each => line(each, 0, [], false)), items);
  return items;
}

function group(by, lines, progress) {
  if (by === "level") return byLevel(lines, progress);
  if (by === "work") return byWork(lines, progress);
  return lines.map(each => line(each, -1, [], false));
}
