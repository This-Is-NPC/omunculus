.pragma library

// The only place a tool name appears: what it is called while it runs, and how
// one call and several of its kind read afterwards. `internal` calls are the
// harness's own bookkeeping, hidden from the person unless they keep failing.
const tools = {
  read: { now: "Reading files", once: "read a file", many: "read {n} files" },
  write: { now: "Writing files", once: "wrote a file", many: "wrote {n} files" },
  edit: { now: "Editing a file", once: "edited a file", many: "edited a file {n} times" },
  ls: { now: "Looking at the project", once: "looked at the project", many: "looked at the project {n} times" },
  ask: { now: "Asking a teammate", once: "asked a teammate", many: "asked a teammate {n} times" },
  escalate: { now: "Passing a question up", once: "passed a question up", many: "passed {n} questions up" },
  reply: { now: "Answering", once: "answered", many: "answered {n} times" },
  work: { now: "Opening work", once: "opened some work", many: "opened {n} pieces of work" },
  next_stage: { now: "Moving to the next step", once: "moved to the next step", many: "tried to move on {n} times", internal: true },
  grant: { now: "Granting a permission", once: "granted a permission", many: "granted {n} permissions" },
  continue: { now: "Moving the work on", once: "moved the work on", many: "moved the work on {n} times" }
};
const unknown = { now: "Working", once: "worked", many: "worked" };
const trouble = 3;

// What a tool is doing while it runs; "Working" for one not in the table.
function phrase(name) { return (tools[name] || unknown).now; }

// Calls ({name, ok, ...}) as {text, failed, failedText, hidden}: the successes
// with consecutive calls of one kind joined ("Read 6 files, wrote a file"),
// the failures counted apart, and the failed internal calls hidden until
// they pass three.
function summarize(calls) {
  const groups = [];
  let failed = 0;
  let internal = 0;
  for (const call of calls) {
    const tool = tools[call.name] || unknown;
    if (call.ok === false) {
      if (tool.internal) internal++;
      else failed++;
      continue;
    }
    const last = groups[groups.length - 1];
    if (last && last.tool === tool) last.n++;
    else groups.push({ tool: tool, n: 1 });
  }
  const stuck = internal > trouble;
  const parts = [];
  if (failed > 0) parts.push(failed + (failed === 1 ? " attempt" : " attempts") + " did not work");
  if (stuck) parts.push("The team is having trouble moving on");
  const text = groups.map(group => group.n === 1 ? group.tool.once : group.tool.many.replace("{n}", group.n)).join(", ");
  return {
    text: text.charAt(0).toUpperCase() + text.slice(1),
    failed: failed + (stuck ? internal : 0),
    failedText: parts.join(". "),
    hidden: stuck ? 0 : internal
  };
}
