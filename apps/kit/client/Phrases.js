.pragma library

// What a tool is called in plain words while it runs, and whether its args
// name the object it opens.
// `act` is the call as a verb ("could not read"), `past` what it did to the
// object it names ("read design/rounds.md").
const tools = {
  read: { now: "Reading files", done: "Read files", act: "read", past: "read" },
  write: { now: "Writing files", done: "Wrote files", act: "write", past: "wrote" },
  edit: { now: "Editing a file", done: "Edited a file", act: "edit", past: "edited" },
  ls: { now: "Looking at the project", done: "Looked at the project", act: "look at", past: "looked in", folder: true },
  grep: { now: "Searching the project", done: "Searched the project", act: "search", past: "searched" },
  find: { now: "Looking for files", done: "Looked for files", act: "look for files in", past: "looked for files in" },
  bash: { now: "Running a command", done: "Ran a command", act: "run a command", past: "ran a command on", command: true },
  ask: { now: "Asking a teammate", done: "Asked a teammate", act: "ask a teammate", past: "asked" },
  escalate: { now: "Passing a question up", done: "Passed a question up", act: "pass a question up", past: "passed a question up to" },
  reply: { now: "Answering", done: "Answered", act: "answer" },
  comment: { now: "Writing a note", done: "Wrote a note", act: "write a note" },
  delegate: { now: "Handing work down", done: "Handed work down", act: "hand work down" },
  work: { now: "Opening work", done: "Opened work", act: "open work", titled: true },
  next_stage: { now: "Moving to the next stage", done: "Moved to the next stage", act: "move to the next stage" },
  grant: { now: "Granting a permission", done: "Granted a permission", act: "grant a permission" },
  continue: { now: "Moving the work on", done: "Moved the work on", act: "move the work on" },
  break: { now: "Asking for fixes", done: "Asked for fixes", act: "ask for fixes" },
  reopen: { now: "Sending work back", done: "Sent work back", act: "send work back" },
  done: { now: "Finishing its part", done: "Finished its part", act: "finish its part" },
  send: { now: "Sending a message", done: "Sent a message", act: "send a message" },
  deploy_preview: { now: "Publishing a preview", done: "Published a preview", act: "publish a preview of the site" },
  promote: { now: "Publishing to production", done: "Published to production", act: "publish the site to production" }
};
const nameLimit = 60;
// The commands that read what they name, and those that list it; a pattern
// command takes its first argument as the pattern, not a file.
const readers = ["cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "fgrep", "rg", "sed", "awk", "file", "stat"];
const listers = ["ls", "find", "tree", "du"];
const patterned = ["grep", "egrep", "fgrep", "rg", "sed", "awk"];
const talkers = ["echo", "printf"];
const unknown = { now: "Working", done: "Made a call" };
// The arg a tool row shows for the tools that name their object by it.
const briefKeys = { read: "path", write: "path", edit: "path", ls: "path", bash: "command", grep: "path", find: "path", ask: "to", escalate: "to" };

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
  const named = tool.folder || tool.command ? object(name, args) : "";
  if (named) {
    const past = verb(name, args);
    return past.charAt(0).toUpperCase() + past.slice(1) + " " + named;
  }
  return title ? tool.done + ": " + title : tool.done;
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

// A command's words, one array per command: quotes dropped, commands split
// at ; & | and line ends outside quotes.
function commands(line) {
  const list = [[]];
  let word = "";
  let quote = "";
  const end = () => { if (word !== "") list[list.length - 1].push(word); word = ""; };
  for (const char of line) {
    if (quote) {
      if (char === quote) quote = ""; else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
    } else if (/\s/.test(char) && char !== "\n") {
      end();
    } else if (/[;&|\n]/.test(char)) {
      end();
      if (list[list.length - 1].length > 0) list.push([]);
    } else {
      word += char;
    }
  }
  end();
  return list.filter(each => each.length > 0);
}

// A path relative to the run's workspace: an absolute prefix up to and
// including the `workspace/` folder (and a conversation's folder in it) goes;
// the machine's scratch folders are named as one.
function relative(word) {
  if (/^\/(?:var\/)?tmp(?:\/|$)/.test(word)) return "a scratch folder";
  const root = /^\/(?:[^/]+\/)*?workspace(?:\/|$)(?:[^/]+\/[0-9a-f]{32}(?:\/|$))?/.exec(word);
  return root ? word.slice(root[0].length) || "the project" : word;
}

// Whether a word is no file: a header ("Host:", "Content-Type: text/html") or
// a URL / host:port.
function remote(word) {
  return /^[A-Za-z][\w-]*:/.test(word) || /^[\w.-]+:\d+(\/|$)/.test(word);
}

// What a shell command touches, as {verb, names}: the files and folders it
// names ("design/README.md", "quotes/"), and how it treats them.
function touched(line) {
  const names = [];
  const verbs = new Set();
  for (const words of commands(line)) {
    const command = words[0].split("/").pop();
    if (talkers.includes(command) || command === "cd") continue;
    const args = [];
    let skip = patterned.includes(command) ? 1 : 0;
    for (let at = 1; at < words.length; at++) {
      const word = words[at];
      if (/^\d*[<>]+$/.test(word)) { at++; continue; }
      if (/^\d*[<>]/.test(word) || word.startsWith("-")) continue;
      if (skip > 0) { skip--; continue; }
      args.push(word);
    }
    // A quoted argument with spaces is words, not a file.
    const found = args.filter((word, at) => !/\s/.test(word) && !/^\d+$/.test(word) && word !== "/dev/null" && !remote(word) && (/\/|\.\w+$/.test(word) || (at === 0 && (listers.includes(command) || readers.includes(command)) && /^[\w.~-]+$/.test(word))))
      .map(word => listers.includes(command) && !/\/$|\.\w+$/.test(word) ? word + "/" : word);
    if (found.length === 0) continue;
    found.map(word => [".", "./"].includes(word) ? "the project" : relative(word.replace(/^\.\//, ""))).forEach(word => { if (!names.includes(word)) names.push(word); });
    verbs.add(readers.includes(command) ? "looked at" : listers.includes(command) ? "looked in" : "");
  }
  return { verb: verbs.size === 1 && !verbs.has("") ? [...verbs][0] : tools.bash.past, names: names };
}

// What a call did to its object, as a verb ("read", "looked at"): a
// command's depends on what it runs.
function verb(name, args) {
  const tool = tools[name];
  return tool.command ? touched(args && typeof args.command === "string" ? args.command : "").verb : tool.past;
}

// The object a call names by its arg, for the tools that have a `past` form
// ("design/rounds.md" for a read, "design/" for a folder, the first files a
// command touches, elided); "" when it names none.
function object(name, args) {
  const tool = tools[name];
  const key = briefKeys[name];
  const given = args && key && typeof args[key] === "string" ? args[key] : "";
  if (!tool || !tool.past) return "";
  if (tool.command) {
    const names = touched(given).names;
    const shown = names.slice(0, 2).join(", ") + (names.length > 2 ? " +" + (names.length - 2) + " more" : "");
    return shown.length > nameLimit ? shown.slice(0, nameLimit - 1) + "…" : shown;
  }
  const path = given.replace(/\s+/g, " ").trim();
  if (tool.folder && ["", ".", "./"].includes(path))
    return "the project";
  return tool.folder && path !== "" && !path.endsWith("/") ? path + "/" : path;
}

// Whether a failed lookup only found nothing (a folder or file not there yet):
// a miss, not a failure.
function missed(name, output) {
  return ["read", "ls", "find", "grep"].includes(name) && /no such (file|directory)|not found/i.test(String(output || ""));
}

// A lookup that found nothing, in the log's words ("found no quotes yet").
function miss(args) {
  const path = args && typeof args.path === "string" ? args.path.replace(/\s+/g, " ").trim().replace(/\/$/, "") : "";
  return path ? "found no " + path + " yet" : "found nothing yet";
}

// A reply, by whom it answers: the person's `answers` passed on (how many
// they gave, 0 when none), else an answer.
function replied(asker, answers) {
  const to = asker ? " " + asker : "";
  return answers > 0 ? "Passed your " + (answers === 1 ? "answer" : "answers") + " to" + (to || " the team") : "Answered" + to;
}

// A finished call as the log's plain sentence ("read design/rounds.md",
// "moved to the next stage").
function step(name, args) {
  const named = object(name, args);
  if (named) return verb(name, args) + " " + named;
  const text = did(name, args);
  return text.charAt(0).toLowerCase() + text.slice(1);
}

// A failed call as the log's plain sentence, before the reason ("could not
// read design/rounds.md").
// A tool as a verb phrase the person reads ("publish the site to
// production"); "" for a tool not in the table.
function act(name) {
  return tools[name] ? tools[name].act : "";
}

function stepFailure(name, args) {
  const tool = tools[name];
  if (!tool) return "could not make a call";
  const named = object(name, args);
  return "could not " + tool.act + (named ? (tool.command ? " on " : " ") + named : "");
}
