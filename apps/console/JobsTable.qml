pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Jobs.js" as Jobs
import "kit/client/Requests.js" as Requests
import "kit/ui"

// JobsTable lists jobs in the DataTable, the live ones first, each with its
// schedule in words, its state as an icon and a word, its next and last fire,
// the share of its fires that succeeded, what they cost, who owns it and where
// it came from. Narrow, a row stacks: the name and its state, the schedule and
// the next fire, the last fire, the figures, then the owner and the origin.
DataTable {
  id: table

  property var jobs: []
  readonly property var order: ["active", "paused", "proposed", "ended", "archived"]

  function ownerOf(job) { return job.owner ? Requests.label(job.owner) : "—" }

  rows: jobs.slice().sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state) || a.name.localeCompare(b.name))
  columns: [
    { title: "name", weight: 0.15 }, { title: "runs", weight: 0.15 }, { title: "state", weight: 0.09 },
    { title: "next fire", weight: 0.10 }, { title: "last fire", weight: 0.13 }, { title: "success", weight: 0.06 },
    { title: "cost", weight: 0.08 }, { title: "owner", weight: 0.11 }, { title: "origin", weight: 0.13 }
  ]
  cells: job => {
    const now = Date.now()
    const ran = job.fires.fires > 0
    return table.compact
      ? [job.name, Jobs.when(job.schedule), Jobs.mark(job.state).word, job.next_fire ? "next " + Jobs.at(job.next_fire, now) : "",
        job.last_fire ? "last " + Jobs.last(job, now) : "", ran ? Jobs.rate(job.fires) + " ok" : "no fires yet", ran ? Jobs.cost(job.fires.usd) : "",
        ownerOf(job), Jobs.origin(job)]
      : [job.name, Jobs.when(job.schedule), Jobs.mark(job.state).word, Jobs.at(job.next_fire, now), Jobs.last(job, now), Jobs.rate(job.fires),
        Jobs.cost(job.fires.usd), ownerOf(job), Jobs.origin(job)]
  }
  tone: (job, column) => column === 2 ? Theme[Jobs.mark(job.state).tone] : ""
  statusIcon: job => Jobs.mark(job.state).icon
  stacked: [[0], [1, 3], [4], [5, 6], [7, 8]]
  status: 2
  decode: true
  tip: job => job.state_reason || ""
  emptyText: "no job yet"
}
