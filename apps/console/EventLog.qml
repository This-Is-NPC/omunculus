import QtQuick
import "kit/client/Time.js" as Time

// EventLog holds the open conversation's events as the rows of its log page.
// `append(line)` takes a line at any rate; a timer moves what was taken into
// `rows` in one pass every 150 ms, so a burst costs one layout, not one per
// event. `clear()` empties it for another conversation; `flush()` moves the
// taken lines at once, as at the end of a history replay.
//
// A line is a plain object with these fields, all required:
//   id    string  the event's cursor, unique
//   at    string  ISO timestamp
//   time  string  local "hh:mm:ss.zzz"
//   type  string  event type (prompt, model, tool, start-run, end-run, ...)
//   who   string  agent or actor name, "" if none
//   run   string  run id, "" if none
//   work  string  work id, "" if none
//   what  string  the event on one line
//   ok    bool    false for a failed tool call or a break
//   asks  bool    a request whose arbiter is the person
//   depth number  the agent's depth in the team, 0 if unknown
//   raw   string  the event's JSON text, parsed only when a row is opened
// Rows hold these roles plus `head`, a run's title ("DESIGNER · run 3 · 14:02:11")
// on the run's first row after another run's, else "", and `day`, the local
// day ("Today", "03 Nov") on the first row of each day, else "".
QtObject {
  id: log

  readonly property ListModel rows: ListModel {}
  // The agents and depths seen, for the log's filters.
  property var agents: []
  property var depths: []

  property var taken: []
  property string lastRun: ""
  property string lastDay: ""
  // Agent -> the runs seen of it, in order.
  property var runsOf: ({})

  function append(line) {
    taken.push(line)
    flushing.start()
  }

  function flush() {
    flushing.stop()
    const lines = taken
    taken = []
    const agents = log.agents.slice()
    const depths = log.depths.slice()
    for (const line of lines) {
      let head = ""
      if (line.run !== "" && line.run !== lastRun) {
        const runs = runsOf[line.who] || (runsOf[line.who] = [])
        if (!runs.includes(line.run))
          runs.push(line.run)
        head = (line.who || "run").toUpperCase() + " · run " + (runs.indexOf(line.run) + 1) + " · " + line.time.slice(0, 8)
      }
      lastRun = line.run
      const day = Time.day(line.at, Date.now())
      const dayHead = day !== lastDay ? day : ""
      lastDay = day
      if (line.who !== "" && !agents.includes(line.who))
        agents.push(line.who)
      if (!depths.includes(line.depth))
        depths.push(line.depth)
      rows.append({ id: line.id, at: line.at, time: line.time, type: line.type, who: line.who, run: line.run, work: line.work,
        what: line.what, ok: line.ok, asks: line.asks, depth: line.depth, raw: line.raw, head: head, day: dayHead })
    }
    if (agents.length !== log.agents.length)
      log.agents = agents
    if (depths.length !== log.depths.length)
      log.depths = depths.sort((a, b) => a - b)
  }

  function clear() {
    flushing.stop()
    taken = []
    lastRun = ""
    lastDay = ""
    runsOf = ({})
    agents = []
    depths = []
    rows.clear()
  }

  // Row `index` as a plain object, safe to keep after the row is gone.
  function row(index) {
    const r = rows.get(index)
    return { id: r.id, at: r.at, time: r.time, type: r.type, who: r.who, run: r.run, work: r.work,
      what: r.what, ok: r.ok, asks: r.asks, depth: r.depth, raw: r.raw, head: r.head, day: r.day }
  }

  property Timer flushing: Timer {
    interval: 150
    onTriggered: log.flush()
  }
}
