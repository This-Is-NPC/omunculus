.pragma library
.import "Time.js" as Time
.import "Usage.js" as Usage

// Scheduled jobs as the Console shows them, from what the jobs routes give:
// a job's schedule in words, its state and its fires' states as an icon and a
// word, the totals, the fire and version history folded from a job's events,
// the form that makes or changes a job and the proposal an agent's
// `propose_job` raises. Pure: nothing here reads the server.

const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function two(n) { return String(n).padStart(2, "0"); }
function hour(h, m) { return two(Number(h)) + ":" + two(Number(m)); }

// A schedule as a person says it: "every 2 hours", "every day at 09:00",
// "every Monday at 09:00"; one it has no words for is quoted.
function when(schedule) {
  const text = String(schedule || "").trim();
  let found = /^every (\d+)([mh])$/.exec(text);
  if (found) {
    const unit = found[2] === "m" ? "minute" : "hour";
    return found[1] === "1" ? "every " + unit : "every " + found[1] + " " + unit + "s";
  }
  found = /^daily at (\d{1,2}):(\d{2})$/.exec(text);
  if (found) return "every day at " + hour(found[1], found[2]);
  const field = text.split(/\s+/);
  if (field.length !== 5) return text !== "" ? "on the schedule " + text : "";
  const minute = field[0], at = field[1], day = field[2], month = field[3], weekday = field[4];
  const exact = /^\d+$/.test(minute) && /^\d+$/.test(at);
  if (exact && month === "*" && day === "*") {
    if (weekday === "*") return "every day at " + hour(at, minute);
    if (weekday === "1-5") return "every weekday at " + hour(at, minute);
    if (/^[0-7]$/.test(weekday)) return "every " + days[Number(weekday) % 7] + " at " + hour(at, minute);
  }
  if (exact && /^\d+$/.test(day) && month === "*" && weekday === "*")
    return "on day " + day + " of every month at " + hour(at, minute);
  if (at === "*" && day === "*" && month === "*" && weekday === "*") {
    if (minute === "0") return "every hour";
    const step = /^\*\/(\d+)$/.exec(minute);
    if (step) return "every " + step[1] + " minutes";
  }
  return "on the schedule " + text;
}

// A participant as a name: an agent's, "issuer:subject" for a person.
function who(participant) {
  if (!participant) return "";
  if (participant.kind === "agent") return participant.agent;
  if (participant.kind === "harness") return "the harness";
  return participant.issuer + ":" + participant.subject;
}

// What a job does: the agent or workflow it is sent to, or the tool it calls.
function target(job) {
  if (job.agent) return job.agent;
  if (job.workflow) return job.workflow + " workflow";
  return job.tool ? job.tool + " tool" : "";
}

const stateMarks = {
  proposed: { icon: "help", word: "PROPOSED", tone: "dim" },
  active: { icon: "clock", word: "ACTIVE", tone: "primary" },
  paused: { icon: "warning", word: "PAUSED", tone: "warning" },
  ended: { icon: "check", word: "ENDED", tone: "dim" },
  archived: { icon: "trash", word: "ARCHIVED", tone: "dim" },
  due: { icon: "clock", word: "DUE", tone: "dim" },
  late: { icon: "warning", word: "LATE", tone: "warning" },
  running: { icon: "spark", word: "RUNNING", tone: "primary" },
  succeeded: { icon: "check", word: "SUCCEEDED", tone: "success" },
  failed: { icon: "close", word: "FAILED", tone: "error" },
  skipped: { icon: "more", word: "SKIPPED", tone: "dim" },
  missed: { icon: "warning", word: "MISSED", tone: "warning" },
  cancelled: { icon: "close", word: "CANCELLED", tone: "dim" }
};

// A job's or a fire's state: {icon, word, tone}, the tone a Theme colour's name.
function mark(state) { return stateMarks[state] || { icon: "more", word: String(state || "").toUpperCase(), tone: "dim" }; }

// The share of fires that ended well, "92%"; "—" before any ran.
function rate(totals) {
  return totals && typeof totals.success_rate === "number" ? Math.round(totals.success_rate * 100) + "%" : "—";
}

// What the fires cost, or "—" for none.
function cost(usd) { return typeof usd === "number" ? Usage.money(usd) : "—"; }

function count(n) { return String(Number(n) || 0); }

// Tokens as a short count: 950, 12.4k, 1.2M.
function tokens(n) {
  const value = Number(n) || 0;
  return value >= 1e6 ? (value / 1e6).toFixed(1) + "M" : value >= 1e4 ? (value / 1e3).toFixed(1) + "k" : String(value);
}

// How long a fire took: "850 ms", "12 s", "3 min 05 s"; "—" for none.
function took(ms) {
  const value = Number(ms) || 0;
  if (value <= 0) return "—";
  if (value < 1000) return value + " ms";
  const seconds = Math.round(value / 1000);
  return seconds < 60 ? seconds + " s" : Math.floor(seconds / 60) + " min " + two(seconds % 60) + " s";
}

// A moment as the lists say it, "Today 07:00"; "—" for none.
function at(iso, now) { return iso ? Time.began(iso, now) : "—"; }

// Where a job came from, "tool by seller"; the author and the channel of its
// latest create or change.
function origin(job) {
  const from = job.origin || {};
  const author = who(from.author);
  return [from.channel || "", author !== "" ? "by " + author : ""].filter(part => part !== "").join(" ");
}

// The last fire as a line: "succeeded · Today 07:00".
function last(job, now) {
  const fire = job.last_fire;
  return fire ? mark(fire.state).word.toLowerCase() + " · " + at(fire.scheduled_for || fire.at, now) : "—";
}

// The jobs of `state` among `items`; "" for every one that is not archived.
function inState(items, state) {
  return items.filter(job => state === "" ? job.state !== "archived" : job.state === state);
}

// The fires among a job's history events, newest first, each as the events
// leave it: its latest state with what earlier ones recorded.
function fires(events) {
  const byId = {};
  const order = [];
  for (const event of events) {
    if (event.op !== "fire") continue;
    if (!byId[event.fire_id]) {
      byId[event.fire_id] = {};
      order.push(event.fire_id);
    }
    Object.assign(byId[event.fire_id], event);
  }
  return order.map(id => {
    const fire = byId[id];
    return {
      id: id, state: fire.state, when: fire.scheduled_for || fire.at, version: fire.version || 0, manual: !!fire.manual,
      took: fire.duration_ms || 0, calls: fire.calls || 0, tokens: (fire.input_tokens || 0) + (fire.output_tokens || 0),
      usd: typeof fire.usd === "number" ? fire.usd : null, conversation: fire.conversation_id || "", reason: fire.reason || ""
    };
  }).reverse();
}

// The changes among a job's history events, newest first, as {version, at,
// author, channel, text}: its creation, each edit with the fields it changed
// and each move between states with its reason.
function changes(events) {
  return events.filter(event => ["create", "change", "transition"].includes(event.op)).map(event => {
    const from = event.origin || {};
    const text = event.op === "create" ? "created"
      : event.op === "change" ? "changed " + Object.keys(event.fields || {}).map(key => key.replace(/_/g, " ")).join(", ")
      : event.from + " to " + event.to + (event.reason ? ": " + event.reason : "");
    return { version: event.version || 0, at: event.at, author: who(from.author), channel: from.channel || "", text: text };
  }).reverse();
}

// ---- The form

const name = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

// A date, "2026-12-31" or "2026-12-31 18:00", read in the person's time, as
// the instant the job ends at; the day alone ends at its last minute. "" for
// a text that is neither.
function endInstant(text) {
  const found = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$/.exec(String(text || "").trim());
  if (!found) return "";
  const date = new Date(Number(found[1]), Number(found[2]) - 1, Number(found[3]), found[4] ? Number(found[4]) : 23, found[5] ? Number(found[5]) : 59);
  return isNaN(date.getTime()) ? "" : date.toISOString();
}

// An instant as the form shows it: "2026-12-31 18:00" in the person's time.
function endText(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  return isNaN(date.getTime()) ? "" : date.getFullYear() + "-" + two(date.getMonth() + 1) + "-" + two(date.getDate()) + " " + two(date.getHours()) + ":" + two(date.getMinutes());
}

// A form for a new job, with `preset` over the blank one: {name, mode ("new"
// per fire or "fixed"), conversation, kind ("agent" or "workflow"), target,
// message, schedule, timezone, condition, end, delivery}.
function blank(preset) {
  return Object.assign({
    name: "", mode: "new", conversation: "", kind: "agent", target: "", message: "", schedule: "",
    timezone: "", condition: "", end: "", delivery: ""
  }, preset || {});
}

// The form of a job that exists, to change it or to copy it.
function fromJob(job) {
  return blank({
    name: job.name, mode: job.conversation_id ? "fixed" : "new", conversation: job.conversation_id || "",
    kind: job.workflow ? "workflow" : "agent", target: job.workflow || job.agent || "", message: job.message || "",
    schedule: job.schedule || "", timezone: job.timezone || "", condition: job.condition || "",
    end: endText(job.end_at), delivery: job.delivery || ""
  });
}

// Why the form cannot be sent yet, as a sentence; "" when it can. `creating`
// asks for the name too.
function problem(form, creating) {
  if (creating && !name.test(form.name)) return "Name it: letters, digits, . _ and -, up to 64.";
  if (form.target === "") return "Choose the " + form.kind + " it runs.";
  if (form.message.trim() === "") return "Write the message it sends.";
  if (form.schedule.trim() === "") return "Say when it runs.";
  if (form.timezone.trim() === "") return "Give the time zone the schedule is in.";
  if (form.mode === "fixed" && form.conversation === "") return "Choose the conversation it goes to.";
  if (form.end.trim() !== "" && endInstant(form.end) === "") return "Write the end as 2026-12-31 or 2026-12-31 18:00.";
  return "";
}

// The body that creates a job, or, with `editing`, changes it: every field of
// the form, an empty value clearing one when editing; the conversation stays
// as it was.
function body(form, editing) {
  const fields = {
    message: form.message.trim(), schedule: form.schedule.trim(), timezone: form.timezone.trim(),
    condition: form.condition.trim(), end_at: endInstant(form.end), delivery: form.delivery
  };
  fields.agent = form.kind === "agent" ? form.target : "";
  fields.workflow = form.kind === "workflow" ? form.target : "";
  if (!editing && form.mode === "fixed") fields.conversation_id = form.conversation;
  if (editing) return fields;
  const sent = { name: form.name, channel: "console" };
  for (const key of Object.keys(fields)) if (fields[key] !== "") sent[key] = fields[key];
  return sent;
}

// What the preview route is asked for a schedule, its zone and its target, from
// a form, or null while they are not given.
function previewOf(fields) {
  const schedule = String(fields.schedule || "").trim();
  const timezone = String(fields.timezone || "").trim();
  const to = fields.agent ? { agent: fields.agent } : fields.workflow ? { workflow: fields.workflow } : fields.tool ? { tool: fields.tool } : null;
  return schedule !== "" && timezone !== "" && to !== null ? { schedule: schedule, timezone: timezone, target: to } : null;
}

// A form as the fields previewOf reads.
function formFields(form) {
  return { schedule: form.schedule, timezone: form.timezone, agent: form.kind === "agent" ? form.target : "", workflow: form.kind === "workflow" ? form.target : "" };
}

// The next fires the preview gives, as the lists say them.
function nextFires(preview, now) {
  return ((preview && preview.next) || []).map(iso => Time.began(iso, now));
}

// The estimate in words: the cost per fire and what it is drawn from, or the
// preview's own sentence when there is no history; never a figure made up.
function estimate(preview) {
  if (!preview) return "";
  const basis = preview.basis ? String(preview.basis) : "";
  if (typeof preview.estimate_usd !== "number")
    return basis !== "" ? basis : "No history for this target yet, so there is no estimate.";
  return "About " + Usage.money(preview.estimate_usd) + " a fire" + (basis !== "" ? ", " + basis : "");
}

// ---- A proposal

// The job an agent's `propose_job` asks to create, as the arguments its
// `approve` option gives `jobs create`; null for a request that proposes none.
function proposal(request) {
  const steps = (request.options || {}).approve;
  const step = Array.isArray(steps) ? steps.find(each => each.name === "jobs" && each.args && each.args.action === "create") : null;
  return step ? step.args : null;
}

// Why the agent proposes it, in its words: the request's reason before the job
// is described in lines, which the card shows as fields.
function reason(request) {
  const text = String(request.reason || "");
  const at = text.search(/\n\njob \S+ as it would run:/);
  return (at >= 0 ? text.slice(0, at) : text).trim();
}

// What a proposal's card says in its heading: "seller proposes a job: morning".
function proposes(asker, job) { return asker + " proposes a job: " + job.name; }

// The lines a proposal's card gives under its heading, as {name, value,
// detail}: what the job sends, when it holds back, when it ends and where its
// replies go; `detail` ones, who it runs as and where, sit behind the card's
// toggle. The schedule and its next fires are the preview's.
function lines(job) {
  const sends = job.tool ? "calls the tool " + job.tool + ", with no model"
    : target(job) + " is sent \u201c" + String(job.message || "") + "\u201d";
  return [
    { name: "SENDS", value: sends, detail: false },
    { name: "ONLY WHEN", value: job.condition ? job.condition + " passes" : "", detail: false },
    { name: "UNTIL", value: job.end_at ? endText(job.end_at) : "", detail: false },
    { name: "DELIVERS", value: job.delivery === "owner_inbox" ? "each reply to the owner's inbox" : "", detail: false },
    { name: "RUNS AS", value: job.owner ? who(job.owner) : "whoever approves it", detail: true },
    { name: "CHAT", value: job.conversation_id ? "a fixed one" : "a new one each fire", detail: true },
    { name: "WORKSPACE", value: job.workspace || "", detail: true }
  ].filter(line => line.value !== "");
}

// ---- The composer's /job

// The words after `/job` in what was typed, or null for text that is not the
// command: "/job" gives "", "/job every day" gives "every day".
function command(text) {
  const found = /^\/job(?:\s+([\s\S]*))?$/i.exec(String(text || "").trim());
  return found ? (found[1] || "").trim() : null;
}

// What the composer says while `/job` is typed, since Enter opens the form
// instead of sending: "" for any other text.
function commandHint(text) {
  return command(text) === null ? "" : "Enter opens the job form";
}
