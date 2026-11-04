.pragma library
.import "Phrases.js" as Phrases

const writeLines = 20;

function lines(text) {
  return typeof text === "string" && text !== "" ? text.replace(/\n$/, "").split("\n") : [];
}

// What a call changes in a file, from its args: an edit's replaced and new
// lines over all its spans, as {removed, added}; a write's first lines and
// how many it writes, as {added, total}; null for any other call.
function diff(name, args) {
  const given = args || {};
  if (name === "edit" && Array.isArray(given.edits) && given.edits.length > 0)
    return given.edits.reduce((all, span) => ({
      removed: all.removed.concat(lines(span && span.old)),
      added: all.added.concat(lines(span && span.new))
    }), { removed: [], added: [] });
  if (name === "write" && typeof given.content === "string") {
    const written = lines(given.content);
    return { added: written.slice(0, writeLines), total: written.length };
  }
  return null;
}

// A turn's steps ({name, ok, text, args, output, outcome, hook?, at?}) as one
// group: how many calls and how many failed (outcomes are not calls), the
// seconds between the first and last step when they carry `at`, and one row
// per step. Hooks that passed fold into one row, where the first of them ran.
function group(steps) {
  const rows = [];
  let calls = 0;
  let failed = 0;
  let hooks = null;
  for (const step of steps) {
    const ok = step.ok !== false;
    if (!step.outcome) {
      calls++;
      if (!ok) failed++;
    }
    if (step.hook && ok) {
      if (hooks) {
        hooks.count++;
        hooks.brief = hooks.count + " hooks ran";
        continue;
      }
      hooks = { name: "hook", brief: "1 hook ran", ok: true, output: "", outcome: false, diff: null, hook: true, count: 1 };
      rows.push(hooks);
      continue;
    }
    rows.push({
      name: step.name,
      brief: step.outcome ? String(step.text || "") : Phrases.brief(step.name, step.args),
      ok: ok,
      output: String(step.output || ""),
      outcome: !!step.outcome,
      diff: step.outcome ? null : diff(step.name, step.args),
      hook: !!step.hook,
      count: 1
    });
  }
  const timed = steps.filter(step => typeof step.at === "number");
  const out = { calls: calls, failed: failed, rows: rows };
  if (timed.length > 0) out.seconds = Math.max(0, timed[timed.length - 1].at - timed[0].at);
  return out;
}
