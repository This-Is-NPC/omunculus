.pragma library
.import "Model.js" as Model
.import "Phrases.js" as Phrases
.import "Requests.js" as Requests

// Text on one line: runs of white space as one space.
function flat(value) {
  return String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").trim();
}

// The first line of a text, flattened.
function first(value) {
  return flat(String(value === undefined || value === null ? "" : value).trim().split("\n")[0]);
}

function plural(count, one, many) { return count + " " + (count === 1 ? one : many); }

// A participant as the log names it: "you" for a person, else the agent.
function party(participant) {
  if (!participant || typeof participant !== "object") return "";
  return Requests.human(participant) ? "you" : participant.agent || "";
}

// Text with ": " before it, or "" when there is none.
function colon(text) { return text ? ": " + text : ""; }

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
  const failed = body.ok === false;
  const output = typeof body.output === "string" ? first(body.output) : "";
  if (hook(body))
    return body.name + " hook " + (failed ? "failed" + colon(output) : "ran");
  const brief = Phrases.brief(body.name, body.args);
  return flat([body.name, brief].join(" ")) + (body.via ? ", after " + body.via : "") + (failed ? " failed" + colon(output) : "");
}

// The works a root `work` event opens, by their titles.
function opened(body) {
  const works = Array.isArray(body.works) ? body.works : [];
  const titles = works.map(work => work && flat(work.title)).filter(title => title);
  if (body.reason === "reopened_by_prompt") return "reopened by a message";
  if (titles.length === 0) return works.length > 0 ? "opened " + plural(works.length, "work", "works") : "work " + flat(body.state || "changed");
  return "opened " + titles[0] + (titles.length > 1 ? " +" + (titles.length - 1) + " more" : "");
}

// What an event says, as one plain sentence for the log: who asks whom what,
// what was passed up, what a tool or hook did. `who` is the event's actor;
// the event itself stays whole in the detail card, never on this line.
function what(type, body, who) {
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
    return count > 0 ? "calls " + plural(count, "tool", "tools") : "replied without text";
  }
  case "tool":
    return tool(given);
  case "start-run":
    return flat((given.agent || who || "a run") + " starts" + (given.depth !== undefined ? " at level " + given.depth : ""));
  case "end-run":
    return given.error ? "run failed" + colon(first(given.error)) : "run ended";
  case "request": {
    const asker = party(given.requester) || who || "someone";
    const asked = party(given.arbiter);
    return asker + (asker === "you" ? " ask " : " asks ") + (asked || "the team") + colon(first(given.reason));
  }
  case "escalate": {
    const parts = Object.keys(given.origins || {});
    return "passed " + plural(parts.length, "question", "questions") + " up" + (parts.length > 0 ? " from " + parts.join(", ") : "");
  }
  case "reply": {
    const said = first(given.body);
    const option = Requests.chosen(given);
    return option ? "chose " + option + (said && said !== option ? colon(said) : "") : "answered" + colon(said);
  }
  case "grant":
    return "granted " + flat(given.name) + (given.scope ? " for the " + given.scope : " for this work");
  case "cancel":
    return "cancelled" + colon(first(given.body));
  case "continue":
    return given.to ? "moved on from " + (given.from || "its stage") + " to " + given.to : "finished" + (given.from ? " at " + given.from : "");
  case "end":
    return "ended";
  case "break":
    return "stopped" + colon(first(given.body));
  case "wait":
    return "waits for a message" + colon(first(given.body));
  case "reopen":
    return "sent back to " + (given.stage || "its stage");
  case "delegate":
    return "handed down" + colon(flat(given.title));
  case "work":
    return opened(given);
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
