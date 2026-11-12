.pragma library
.import "Phrases.js" as Phrases

// What a media type is, in a word the client reads; "file" for any other.
const formats = {
  "text/markdown": "document",
  "text/plain": "text",
  "text/html": "web page",
  "application/json": "data",
  "application/pdf": "PDF"
};

// What a media type is called: "document", "data", "image", "file".
function format(mediaType) {
  const type = String(mediaType || "");
  return formats[type] || (type.startsWith("image/") ? "image" : "file");
}

// The heading of an artifact's versions: its title, its kind when that says
// more than the title or the format, and what it is: "Proposal · data".
function heading(artifact) {
  const name = Phrases.document(artifact.name);
  const versions = artifact.versions || [];
  const kind = String(artifact.kind || "");
  const what = versions.length > 0 ? format(versions[0].media_type) : "";
  const known = [name, what].map(word => word.toLowerCase());
  return [name !== "" ? name : kind, name !== "" && !known.includes(kind.toLowerCase()) ? kind : "", what]
    .filter(part => part !== "").join("  \u00b7  ");
}

// The works to show: those that made a file and every work above them, as
// the `keep` of Tree.rows. `flat` is Progress's list of works.
function kept(flat, versions) {
  const byId = {};
  for (const node of flat) byId[node.work] = node;
  const keep = {};
  for (const entry of versions)
    for (let node = byId[entry.version.work_id]; node && !keep[node.work]; node = byId[node.parent])
      keep[node.work] = true;
  return keep;
}

// The files each work made, under the works of the tree, for BY WORK. `rows`
// are Tree.rows with every work kept (see `kept`); `versions` the route's
// versions flattened, each {name, version} with the `work_id` that made it
// (none: the agent that talks with the person, the front row). A work's file
// is the latest version it wrote of a name. Returns {kind: "work", key, row,
// files} and, after each, its {kind: "file", key, row, name, version, last};
// versions of a work the rows lack come last as {kind: "loose", key, name,
// version}. `last` is false while works follow, so the lifeline goes on.
function byWork(rows, versions) {
  if (versions.length === 0) return [];
  const own = {};
  const loose = [];
  const known = new Set(rows.map(row => row.key));
  for (const entry of versions) {
    const key = entry.version.work_id || "front";
    if (!known.has(key)) {
      loose.push({ kind: "loose", key: "loose:" + entry.name, name: entry.name, version: entry.version });
      continue;
    }
    own[key] = own[key] || {};
    own[key][entry.name] = entry.version;
  }
  const items = [];
  for (const row of rows) {
    const names = Object.keys(own[row.key] || {});
    items.push({ kind: "work", key: row.key, row: row, files: names.length });
    names.forEach((name, i) => items.push({
      kind: "file", key: row.key + ":" + name, row: row, name: name, version: own[row.key][name],
      last: i === names.length - 1 && !row.stem
    }));
  }
  return items.concat(loose);
}
