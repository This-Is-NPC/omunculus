.pragma library

// What a tool is called in plain words while it runs, and whether its args
// name the object it opens.
const tools = {
  read: { now: "Reading files", done: "Read files" },
  write: { now: "Writing files", done: "Wrote files" },
  edit: { now: "Editing a file", done: "Edited a file" },
  ls: { now: "Looking at the project", done: "Looked at the project" },
  ask: { now: "Asking a teammate", done: "Asked a teammate" },
  escalate: { now: "Passing a question up", done: "Passed a question up" },
  reply: { now: "Answering", done: "Answered" },
  work: { now: "Opening work", done: "Opened work", titled: true },
  next_stage: { now: "Moving to the next stage", done: "Moved to the next stage" },
  grant: { now: "Granting a permission", done: "Granted a permission" },
  continue: { now: "Moving the work on", done: "Moved the work on" }
};
const unknown = { now: "Working", done: "Made a call" };
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
  return title ? tool.now + ": " + title : tool.now;
}

// What a finished call did ("Passed a question up"), with the title of its
// object like `phrase`; "Made a call" for a tool not in the table.
function did(name, args) {
  const tool = tools[name] || unknown;
  const title = titleOf(tool, args);
  return title ? tool.done + ": " + title : tool.done;
}

// What a failed call was doing, in plain words after "failed:" ("moving to
// the next stage"); "a call" for a tool not in the table.
function failure(name) {
  const tool = tools[name];
  return tool ? tool.now.charAt(0).toLowerCase() + tool.now.slice(1) : "a call";
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
