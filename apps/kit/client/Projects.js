.pragma library

// The projects of a server's registry as the projects page lists them, from
// what was read of each: its conversations, its works and each
// conversation's summary.

// One row per project of `input`:
//   {projects: [{id, socket}], conversations: project id -> [conversation],
//    works: project id -> [work], summaries: conversation id -> {running, waiting},
//    unreachable: Set of project ids, current: the window's project id}
// A project whose socket did not answer counts nothing waiting or working:
// what was read of it may be stale. One whose conversations are not read yet
// is "reading".
function rows(input) {
  return input.projects.map(place => {
    const conversations = input.conversations[place.id];
    const works = input.works[place.id] || [];
    const reachable = !input.unreachable.has(place.id);
    const summaries = (conversations || []).map(conversation => input.summaries[conversation.id] || {});
    const waiting = reachable ? summaries.reduce((sum, summary) => sum + (summary.waiting || 0), 0) : 0;
    const working = reachable ? summaries.reduce((sum, summary) => sum + (summary.running || 0), 0) : 0;
    const stamps = (conversations || []).map(conversation => conversation.created_at)
      .concat(works.map(work => work.updated_at))
      .filter(stamp => stamp);
    return {
      id: place.id,
      socket: place.socket,
      current: place.id === input.current,
      reachable: reachable,
      conversations: (conversations || []).length,
      openWorks: works.filter(work => work.state !== "done" && work.state !== "cancelled").length,
      waiting: waiting,
      working: working,
      last: stamps.reduce((newest, stamp) => stamp > newest ? stamp : newest, ""),
      state: !reachable ? "unreachable"
        : conversations === undefined ? "reading"
        : waiting > 0 ? "waiting"
        : working > 0 ? "working"
        : "idle"
    };
  });
}

// Waiting for you first (most first), then working, then the latest
// activity, then the id.
function sort(rows) {
  return rows.slice().sort((a, b) => b.waiting - a.waiting || b.working - a.working
    || (a.last < b.last ? 1 : a.last > b.last ? -1 : 0)
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

// The rows in the state `chip` ("" for all, "waiting" or "working") whose id
// holds every word of `text`.
function filter(rows, text, chip) {
  const words = String(text).toLowerCase().split(/\s+/).filter(word => word);
  return rows.filter(row => (chip === "" || row.state === chip)
    && words.every(word => row.id.toLowerCase().includes(word)));
}

// The requests waiting for you in the projects the window is not on.
function elsewhere(rows) {
  return rows.filter(row => !row.current).reduce((sum, row) => sum + row.waiting, 0);
}

// A project's conversations and open works in at most `budget` characters:
// the first that fits of "15 conversations · 14 open works", "15
// conversations · 14 open", "15 conversations", "15 conv." and "15"; the
// open works only while there are some.
function conversationsText(count, open, budget) {
  const named = count + (count === 1 ? " conversation" : " conversations");
  const works = open > 0 ? [named + " · " + open + (open === 1 ? " open work" : " open works"), named + " · " + open + " open"] : [];
  return works.concat([named, count + " conv.", String(count)]).find(text => text.length <= budget) || "";
}
