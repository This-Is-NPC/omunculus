.pragma library

// What a tool is called in plain words while it runs, and whether its args
// name the object it opens.
// `act` is the call as a verb ("could not read"), `past` what it did to the
// object it names ("read design/rounds.md").
const tools = {
  read: { now: "Reading files", done: "Read files", act: "read", past: "read" },
  write: { now: "Writing files", done: "Wrote files", act: "write", past: "wrote" },
  edit: { now: "Editing a file", done: "Edited a file", act: "edit", past: "edited" },
  ls: { now: "Looking at the project", done: "Looked at the project", act: "look at", past: "looked at" },
  grep: { now: "Searching the project", done: "Searched the project", act: "search", past: "searched" },
  find: { now: "Looking for files", done: "Looked for files", act: "look for files in", past: "looked for files in" },
  bash: { now: "Running a command", done: "Ran a command", act: "run a command" },
  ask: { now: "Asking a teammate", done: "Asked a teammate", act: "ask a teammate", past: "asked" },
  escalate: { now: "Passing a question up", done: "Passed a question up", act: "pass a question up", past: "passed a question up to" },
  reply: { now: "Answering", done: "Answered", act: "answer" },
  comment: { now: "Writing a note", done: "Wrote a note", act: "write a note" },
  delegate: { now: "Handing work down", done: "Handed work down", act: "hand work down" },
  work: { now: "Opening work", done: "Opened work", act: "open work", titled: true },
  next_stage: { now: "Moving to the next stage", done: "Moved to the next stage", act: "move to the next stage" },
  grant: { now: "Granting a permission", done: "Granted a permission", act: "grant a permission" },
  continue: { now: "Moving the work on", done: "Moved the work on", act: "move the work on" },
  break: { now: "Stopping the work", done: "Stopped the work", act: "stop the work" },
  reopen: { now: "Sending work back", done: "Sent work back", act: "send work back" },
  send: { now: "Sending a message", done: "Sent a message", act: "send a message" }
};
const unknown = { now: "Working", done: "Made a call" };
// The arg a tool row shows for the tools that name their object by it.
const briefKeys = { read: "path", write: "path", edit: "path", ls: "path", grep: "path", find: "path", ask: "to", escalate: "to" };

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

// The object a call names by its arg, for the tools that have a `past` form
// ("design/rounds.md" for a read); "" when it names none.
function object(name, args) {
  const tool = tools[name];
  const key = briefKeys[name];
  const given = args && key && typeof args[key] === "string" ? args[key] : "";
  return tool && tool.past ? given.replace(/\s+/g, " ").trim() : "";
}

// A finished call as the log's plain sentence ("read design/rounds.md",
// "moved to the next stage").
function step(name, args) {
  const named = object(name, args);
  if (named) return tools[name].past + " " + named;
  const text = did(name, args);
  return text.charAt(0).toLowerCase() + text.slice(1);
}

// A failed call as the log's plain sentence, before the reason ("could not
// read design/rounds.md").
function stepFailure(name, args) {
  const tool = tools[name];
  if (!tool) return "could not make a call";
  const named = object(name, args);
  return "could not " + tool.act + (named ? " " + named : "");
}
