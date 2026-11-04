.pragma library

// How a tool reads in plain words: what it is called while it runs, and how
// one call and several of its kind read afterwards.
const tools = {
  read: { now: "Reading files", once: "read a file", many: "read {n} files" },
  write: { now: "Writing files", once: "wrote a file", many: "wrote {n} files" },
  edit: { now: "Editing a file", once: "edited a file", many: "edited a file {n} times" },
  ls: { now: "Looking at the project", once: "looked at the project", many: "looked at the project {n} times" },
  ask: { now: "Asking a teammate", once: "asked a teammate", many: "asked a teammate {n} times" },
  escalate: { now: "Passing a question up", once: "passed a question up", many: "passed {n} questions up" },
  reply: { now: "Answering", once: "answered", many: "answered {n} times" },
  work: { now: "Opening work", once: "opened some work", many: "opened {n} pieces of work", titled: { now: "Opening work", once: "opened work" } },
  next_stage: { now: "Moving to the next step", once: "moved to the next step", many: "tried to move on {n} times" },
  grant: { now: "Granting a permission", once: "granted a permission", many: "granted {n} permissions" },
  continue: { now: "Moving the work on", once: "moved the work on", many: "moved the work on {n} times" }
};
const unknown = { now: "Working", once: "worked", many: "worked" };
// The arg a tool row shows for the tools that name their object by it.
const briefKeys = { read: "path", write: "path", edit: "path", ls: "path", ask: "to", escalate: "to" };

// The title of the object a call names, for the tools that name theirs: the
// first of a `work` call's works, with "+N more" when it opens several.
function titleOf(tool, args) {
  const works = tool.titled && args && Array.isArray(args.works) ? args.works : [];
  const title = works.length > 0 && works[0] && typeof works[0].title === "string" ? works[0].title : "";
  return title !== "" && works.length > 1 ? title + " +" + (works.length - 1) + " more" : title;
}

// What a tool is doing while it runs, with the title of its object when the
// call's args carry one ("Opening work: Bakery website"); "Working" for a tool
// not in the table.
function phrase(name, args) {
  const tool = tools[name] || unknown;
  const title = titleOf(tool, args);
  return title ? tool.titled.now + ": " + title : tool.now;
}

// What a tool row shows after the tool's name: the path for the file tools,
// whom an ask or escalate goes to, the first work a work call opens, else
// the first string arg; "" when the call has none.
function brief(name, args) {
  const given = args || {};
  const key = briefKeys[name];
  let shown = key && typeof given[key] === "string" ? given[key] : "";
  if (shown === "" && name === "work") shown = titleOf(tools.work, given);
  if (shown === "") shown = Object.values(given).find(value => typeof value === "string" && value.trim() !== "") || "";
  return shown.replace(/\s+/g, " ").trim();
}

// Calls ({name, ok, args?, ...}) as {text, failed, failedText}: the successes
// with consecutive calls of one kind joined ("Read 6 files, wrote a file"),
// and every failure counted apart.
function summarize(calls) {
  const groups = [];
  let failed = 0;
  for (const call of calls) {
    const tool = tools[call.name] || unknown;
    if (call.ok === false) {
      failed++;
      continue;
    }
    const last = groups[groups.length - 1];
    if (last && last.tool === tool) last.n++;
    else groups.push({ tool: tool, n: 1, title: titleOf(tool, call.args) });
  }
  const text = groups.map(group => group.n === 1 ? (group.title ? group.tool.titled.once + ": " + group.title : group.tool.once) : group.tool.many.replace("{n}", group.n)).join(", ");
  return {
    text: text.charAt(0).toUpperCase() + text.slice(1),
    failed: failed,
    failedText: failed > 0 ? failed + (failed === 1 ? " attempt" : " attempts") + " did not work" : ""
  };
}
