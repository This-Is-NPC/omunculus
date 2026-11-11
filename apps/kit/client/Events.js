.pragma library
.import "Model.js" as Model
.import "Phrases.js" as Phrases
.import "Questions.js" as Questions
.import "Requests.js" as Requests

// Text on one line: runs of white space as one space.
function flat(value) {
  return String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim();
}

// The first line of a text, flattened.
function first(value) {
  return flat(String(value === undefined || value === null ? "" : value).trim().split("\n")[0]);
}

// Why a failed call failed, on one line: a command's error is the last line
// of its output before the "(exit N)" trailer the bash tool adds (kept only
// when nothing else was printed), any other tool's the first.
function reason(name, output) {
  const lines = String(output === undefined || output === null ? "" : output).split("\n").map(flat).filter(line => line !== "");
  if (name !== "bash") return lines[0] || "";
  const printed = lines.filter(line => !/^\(exit \d+\)$/.test(line));
  return (printed.length > 0 ? printed : lines).slice(-1)[0] || "";
}

// A failure's reason with no harness ids; the refusal of a work still broken
// below the caller reads as what it means.
function plain(text) {
  return /^refused: work \S+ below yours broke/.test(text) ? "a work below is still open" : flat(unid(text));
}

function plural(count, one, many) { return count + " " + (count === 1 ? one : many); }

// A participant as the log names it: "you" for the viewer `me`, else its name.
function party(participant, me) {
  if (!participant || typeof participant !== "object") return "";
  return Requests.party(participant, me);
}

// What a released event adds to its line: the review that let it go ahead.
function released(id) {
  return id ? " \u00b7 released by review #" + String(id).slice(0, 8) : "";
}

// Text without the harness ids the model echoes: "request <hex>" and bare
// hex runs of 12 characters or more, outside web addresses, whose hosts and
// paths may hold such runs.
function unid(text) {
  return String(text === undefined || text === null ? "" : text)
    .split(/(\bhttps?:\/\/\S+)/i)
    .map((part, i) => i % 2 ? part : part
      .replace(/\s*\(?\brequests?\s+[0-9a-f]{12,}\w*\)?/gi, "")
      .replace(/\b(?=[0-9a-f]*\d)[0-9a-f]{12,}\b/gi, "")
      .replace(/[ \t]{2,}/g, " "))
    .join("");
}

// Text the person reads: no ids, and no "on work" left dangling by one.
function readable(text) {
  return unid(text).replace(/\bon work\s+(?=[,.;)]|$)/gi, "").replace(/ +(?=[,.;])/g, "");
}

// Text with ": " before it, or "" when there is none.
function colon(text) { return text ? ": " + text : ""; }

// How many questions a request text asks: its numbered items, else one.
function questions(text) {
  const form = Questions.parse(text);
  return form ? form.items.length : 1;
}

// How many tool calls a model reply without text makes, in the shapes
// Model.text reads; 0 when none is recognised.
function calls(body) {
  if (!body || typeof body !== "object") return 0;
  const isCall = part => part && ["tool_use", "function_call"].includes(part.type);
  const listed = ["content", "output"].map(key => Array.isArray(body[key]) ? body[key].filter(isCall).length : 0);
  const choices = Array.isArray(body.choices) ? body.choices : [];
  const tools = choices.concat([body]).map(each => each.message || each)
    .map(message => Array.isArray(message.tool_calls) ? message.tool_calls.length : 0);
  return listed.concat(tools).reduce((sum, count) => sum + count, 0);
}

// Whether a tool call is a hook: hooks are called with the event alone.
function hook(body) {
  const args = body.args;
  return !!args && typeof args === "object" && typeof args.event === "object" && Object.keys(args).length === 1;
}

function tool(body) {
  if (body.ok === false && Phrases.missed(body.name, body.output))
    return Phrases.miss(body.args);
  const failed = body.ok === false;
  const output = typeof body.output === "string" ? plain(reason(body.name, body.output)) : "";
  if (hook(body))
    return body.name + " hook " + (failed ? "failed" + colon(output) : "ran");
  if (body.name === "end")
    return failed ? "could not finish" + colon(output) : body.via === "escalate" ? "finished after passing up" : "finished";
  if (body.name === "assemble")
    return "got ready" + (failed ? ", failed" + colon(output) : "");
  return failed ? Phrases.stepFailure(body.name, body.args) + colon(output) : Phrases.step(body.name, body.args);
}

// The works a root `work` event opens, by their titles.
function opened(body, titled) {
  const works = Array.isArray(body.works) ? body.works : [];
  const titles = works.map(work => work && flat(work.title)).filter(title => title);
  if (body.reason === "reopened_by_prompt") return "reopened by a message";
  if (titles.length === 0) return works.length > 0 ? "opened " + plural(works.length, "work", "works") : (titled || "a work") + (body.state ? " is now " + flat(body.state) : " changed");
  return "opened " + titles[0] + (titles.length > 1 ? " +" + (titles.length - 1) + " more" : "");
}

// What an event says, as one plain sentence for the log: who asks whom what,
// what was passed up, what a tool or hook did. `who` is the event's actor;
// the event itself stays whole in the detail card, never on this line.
// `asked` maps a request id to how many questions it asked, `askers` to who
// asked; `requestId` is the event's own request; `titled` the title of the
// event's work, "" when unknown; `me` the viewer, whom the log calls "you".
function what(type, body, who, asked, requestId, askers, titled, me) {
  const given = body && typeof body === "object" ? body : {};
  switch (type) {
  case "prompt":
    return flat(given.message);
  case "comment":
    return flat(given.body);
  case "model": {
    const said = flat(Model.text(body));
    if (said) return said;
    const count = calls(given);
    return count > 0 ? "planned " + plural(count, "step", "steps") : "had nothing to add";
  }
  case "tool":
    return tool(given);
  case "start-run":
    return flat((given.agent || who || "a run") + " started");
  case "end-run":
    return given.error ? "run failed" + colon(first(given.error)) : "run finished";
  case "request": {
    const asker = party(given.requester, me) || who || "someone";
    const arbiter = party(given.arbiter, me);
    if (given.interception) {
      const held = given.interception;
      return flat(held.summary) + " \u00b7 for " + (arbiter || "the team") + (held.of > 1 ? " \u00b7 step " + held.step + " of " + held.of : "");
    }
    const count = questions(given.reason);
    const how = count > 1 ? " " + plural(count, "question", "questions") : "";
    return asker + (asker === "you" ? " ask " : " asks ") + (arbiter || "the team") + how + colon(count > 1 ? first(Questions.parse(given.reason).intro) : first(given.reason));
  }
  case "escalate": {
    // The question it asks, as asked: the same count at each hop, whatever the
    // origins' own wording counted.
    const known = asked || {};
    const own = given.reason ? questions(given.reason) : known[requestId];
    const total = own || Object.values(given.origins || {}).reduce((sum, id) => sum + (known[id] || 1), 0);
    return "passed " + plural(total, "question", "questions") + " up";
  }
  case "reply": {
    const said = first(unid(given.body));
    const option = Requests.chosen(given);
    const asker = (askers || {})[requestId];
    const words = option ? Requests.optionText(option).toLowerCase() : "";
    if (option === "grant") return "granted" + (asker ? " for " + asker : "");
    return option ? "chose " + words + (asker ? " for " + asker : "") + (said && said !== option ? colon(said) : "") : "answered" + (asker ? " " + asker : "") + colon(said);
  }
  case "release": {
    const option = given.option === "edit" ? "edited and released" : "released";
    return option + ": " + flat(given.summary);
  }
  case "grant":
    return "granted: " + (Phrases.act(given.name) || flat(given.name)) + (given.scope ? ", for the " + given.scope : ", for this work");
  case "cancel":
    return "cancelled" + colon(first(given.body));
  case "continue":
    return given.to ? "moved on from " + (given.from || "its stage") + " to " + given.to : "finished" + (given.from ? " at " + given.from : "");
  case "end":
    return "finished";
  case "break":
    return "stopped" + colon(first(given.body));
  case "wait":
    return "waits for a message" + colon(first(given.body));
  case "reopen":
    return "sent back to " + (given.stage || "its stage");
  case "delegate":
    return "handed down" + colon(flat(given.title));
  case "work":
    return opened(given, titled);
  case "artifact":
    return "saved " + (Phrases.document(given.name) || "a document") + (given.version ? ", version " + given.version : "");
  case "notify":
    return "notified" + colon(first(given.body));
  case "attach": {
    const files = Array.isArray(given.attachments) ? given.attachments.length : 0;
    return "attached " + plural(files, "file", "files");
  }
  case "compact":
    return "summed up " + plural(Array.isArray(given.deleted) ? given.deleted.length : 0, "comment", "comments");
  case "comment.delete":
    return "deleted " + plural(Array.isArray(given.ids) ? given.ids.length : 0, "comment", "comments");
  case "inbox.read":
    return "read a notice";
  case "access.bootstrap":
    return "joined the project" + (given.role ? " as " + given.role : "");
  default:
    return flat(type.replace(/[.\-_]/g, " "));
  }
}

// Tools whose result is an event row of its own (note, delegate, question,
// move on...): their step row only repeats it.
const echoed = ["put_artifact", "comment", "delegate", "ask", "escalate", "continue", "next_stage", "work", "reply", "grant", "break", "reopen", "send"];

// Whether an event is plumbing: it carries no news for the person — a run's
// start and end, a hook, a model reply without text, a call whose result has
// an event row of its own.
function minor(type, body) {
  const given = body && typeof body === "object" ? body : {};
  if (type === "tool" && given.ok === false && Phrases.missed(given.name, given.output))
    return true;
  switch (type) {
  case "start-run":
  case "end":
    return true;
  case "reply":
    // The same answer passed down a level: the leaf reply is the one.
    return !!given.parts && Object.keys(given.parts).length > 0;
  case "end-run":
    return !given.error;
  case "tool":
    return given.ok !== false && (hook(given) || ["end", "assemble"].concat(echoed).includes(given.name));
  case "model":
    return !Model.text(body);
  default:
    return false;
  }
}

// What the log's chips count among `count` rows, read with `at(index)`:
// {asks, failed, minor}. A row asks while `waits(row)`; it failed unless it
// is ok or retried; plumbing is minor, but a run's first row is always shown.
function tally(count, at, waits) {
  const found = { asks: 0, failed: 0, minor: 0 };
  for (let index = 0; index < count; index++) {
    const line = at(index);
    if (waits(line)) found.asks++;
    if (!line.ok && !line.retried) found.failed++;
    if (line.minor && line.head === "") found.minor++;
  }
  return found;
}

// An event's kind as the person reads it.
function kind(type, body) {
  switch (type) {
  case "prompt": return "message";
  case "comment": return "note";
  case "model": return "reply";
  case "tool": return body && typeof body === "object" && hook(body) ? "hook" : "step";
  case "start-run":
  case "end-run": return "run";
  case "request": return Requests.mark(body && typeof body === "object" ? body : {}).one;
  case "release": return "released";
  case "escalate": return "passed up";
  case "reply": return "answer";
  case "break": return "stopped";
  default: return flat(type.replace(/[.\-_]/g, " "));
  }
}
