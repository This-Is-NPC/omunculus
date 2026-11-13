.pragma library
.import "Mailbox.js" as Mailbox

// The mailbox's composers: the messages being written, each in a window of its
// own docked at the bottom right, as a mail client keeps them. Everything here
// is pure: the state is {items, active, seq}, every change returns the next
// one, and the window draws it. An item is {id, kind, draft, subject, body, to,
// thread, request, quoted, mode} with `kind` "new", "reply", "forward" or "job"
// (a new message answering a job's) and
// `mode` "open" (docked, or the active one on a phone), "min" (a tab) or
// "full" (expanded over a dim backdrop).

const windowWidth = 360, tabWidth = 200, tabLeast = 48, gap = 8;

function empty() { return { items: [], active: "", seq: 0 }; }

// What the composer for a reply to `key` of `thread` starts with, `key` "" for
// the latest message. `when` writes a date as the person reads it.
function replying(thread, key, all, when) {
  const last = thread.messages[thread.messages.length - 1];
  const message = thread.messages.find(each => each.key === key) || last;
  if (!message) return null;
  if (thread.job) return Mailbox.jobReply(thread, message, when(message.at));
  const target = Mailbox.replyTarget(thread, message.key);
  return {
    kind: "reply", thread: thread.key, replied: message.key, subject: Mailbox.re(thread.subject), body: "",
    to: Mailbox.replyRecipients(thread, message, !!all), request: target.request,
    quoted: target.quoted ? Mailbox.quoted(target.quoted, when(target.quoted.at)) : null
  };
}

// Opens a composer from `preset`: {kind, subject, body, to, ...} as `replying`
// gives, {draft} for a saved draft, {subject, body} for a forward, or {} for
// a new message. One already open for the same draft or reply is shown again
// instead of a second.
function open(state, preset) {
  const same = state.items.find(item => (preset.draft && item.draft === preset.draft.id)
    || (preset.replied && item.thread === preset.thread && item.replied === preset.replied));
  if (same) return activate(state, same.id);
  const saved = preset.draft || null;
  const id = "c" + (state.seq + 1);
  const item = {
    id: id, kind: preset.kind || "new", draft: saved ? saved.id : "",
    subject: saved ? saved.subject : preset.subject || "", body: saved ? saved.body : preset.body || "",
    to: saved ? (saved.agent !== "" ? [Mailbox.person(saved.agent, saved.project)] : []) : preset.to || [],
    thread: preset.thread || "", replied: preset.replied || "", request: preset.request || "", quoted: preset.quoted || null, mode: "open"
  };
  const items = state.items.map(each => each.mode === "full" ? Object.assign({}, each, { mode: "open" }) : each);
  return { items: items.concat([item]), active: id, seq: state.seq + 1 };
}

function change(state, id, mode, active) {
  if (!state.items.some(item => item.id === id)) return state;
  return Object.assign({}, state, {
    items: state.items.map(item => item.id === id ? Object.assign({}, item, { mode: mode })
      : mode === "full" && item.mode === "full" ? Object.assign({}, item, { mode: "open" }) : item),
    active: active
  });
}

// Collapses it to a tab; its words stay.
function minimize(state, id) { return change(state, id, "min", state.active === id ? "" : state.active); }
// Opens it again, docked, and makes it the active one.
function activate(state, id) {
  const item = state.items.find(each => each.id === id);
  return item ? change(state, id, item.mode === "full" ? "full" : "open", id) : state;
}
// Expands it over the window, or, when it is, docks it again.
function expand(state, id) {
  const item = state.items.find(each => each.id === id);
  return item ? change(state, id, item.mode === "full" ? "open" : "full", id) : state;
}
function close(state, id) {
  return Object.assign({}, state, { items: state.items.filter(item => item.id !== id), active: state.active === id ? "" : state.active });
}

// Whether closing the composer loses something: `now` is {subject, body, files}
// as the window holds them. Words of the baseline it started with, the quote of
// a forward, do not count; a new message's subject does.
function written(item, now) {
  return now.files > 0 || now.body.trim() !== item.body.trim() || (item.kind === "new" && now.subject.trim() !== "");
}

// The title of a composer's bar.
function title(subject) {
  return subject.trim() !== "" ? subject.trim() : "New message";
}

// Where the docked composers go in a window `width` wide: [{id, shape, x,
// width}] from oldest, on the left, to newest, on the right, which keeps the
// right margin. An open composer is a window while there is room for it, from
// the newest back; the others, minimized or crowded out, are tabs, narrower
// as they grow in number. The expanded one is not docked.
function layout(state, width, margin) {
  const docked = state.items.filter(item => item.mode !== "full");
  let room = width - 2 * margin;
  const shapes = [];
  const newest = docked.slice().reverse();
  for (const [at, item] of newest.entries()) {
    // Older composers keep a tab's room; the newest is a window whenever it fits.
    const older = newest.length - at - 1;
    const fits = item.mode === "open" && room >= windowWidth + (at === 0 ? 0 : older * (tabLeast + gap));
    room -= (fits ? windowWidth : tabLeast) + gap;
    shapes.unshift(fits ? "window" : "tab");
  }
  const windows = shapes.filter(shape => shape === "window").length;
  const tabs = shapes.length - windows;
  const left = width - 2 * margin - windows * windowWidth - Math.max(0, shapes.length - 1) * gap;
  const each = tabs === 0 ? 0 : Math.max(tabLeast, Math.min(tabWidth, Math.floor(left / tabs)));
  const sizes = shapes.map(shape => shape === "window" ? windowWidth : each);
  let x = width - margin - sizes.reduce((sum, size) => sum + size, 0) - Math.max(0, shapes.length - 1) * gap;
  return docked.map((item, at) => {
    const slot = { id: item.id, shape: shapes[at], x: x, width: sizes[at] };
    x += sizes[at] + gap;
    return slot;
  });
}

// What a phone shows: the tab strip of every composer, and the active one
// that fills the screen, "" when none does and the strip sits under the mailbox.
function phone(state) {
  const item = state.items.find(each => each.id === state.active);
  return { tabs: state.items.map(each => each.id), active: item && item.mode !== "min" ? item.id : "" };
}
