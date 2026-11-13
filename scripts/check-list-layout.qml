import QtQuick
import Quickshell
import "kit/ui"

// A render loop of the mailbox's thread list at 390 px: threads arrive, change
// their label (a row of another height), move and leave, as sweeps bring them,
// and a second after each burst every row must sit under the one above it and
// clear of the section titles. Prints "RESULT <rows checked> <faults>".
ShellRoot {
  FloatingWindow {
    id: win
    implicitWidth: 400
    implicitHeight: 860
    color: Theme.background

    // The window opens wide and is narrowed, as a phone's is.
    Item {
      id: host
      width: 1240
      height: 800
      ThreadList { id: list; anchors { fill: parent; margins: 16 } }
    }

    property int step: 0
    property int checked: 0
    property int faults: 0

    function thread(i, at, extra) {
      return Object.assign({
        key: "agency/c" + i, project: "agency", id: "c" + i, agent: "front-desk",
        with: { agent: "front-desk", project: "agency", name: "Front desk", address: "", text: "" },
        subject: "Reply with a two-line status of the project " + i, label: "", messages: [], pending: [], reviews: [],
        at: at, heard: at, received: 2, sent: 1, parties: "Front desk, me (2)", snippet: "Here is a short status of the project " + i
      }, extra || {})
    }

    function arrive() {
      const all = {}
      for (let i = 0; i < 9; i++)
        all["agency/c" + i] = thread(i, i < 6 ? "2026-11-13T0" + (5 - i) + ":00:00" : "2026-11-12T10:00:0" + i, i === 0 ? { label: "progress" } : {})
      all["agency/job:j1"] = thread("job", "2026-11-13T04:55:00", { key: "agency/job:j1", id: "job:j1", parties: "morning-status (2)", subject: "morning-status", label: "job", job: { id: "j1", name: "m" } })
      Mail.threads = all
      Mail.primed = true
    }

    function change() {
      step++
      const all = Object.assign({}, Mail.threads)
      for (const key of Object.keys(all)) {
        const next = Object.assign({}, all[key])
        if ((step * 7 + key.length * 13 + key.charCodeAt(key.length - 1)) % 11 < 4)
          next.label = next.label === "progress" ? "" : "progress"
        if (step % 5 === 0 && key === "agency/c2")
          next.at = "2026-11-13T0" + (step % 9) + ":30:00"
        all[key] = next
      }
      if (step === 4)
        all["agency/c99"] = thread(99, "2026-11-13T06:00:00")
      if (step === 8)
        delete all["agency/c1"]
      Mail.threads = all
    }

    function inspect() {
      let view = null
      for (const child of list.children)
        if (child.hasOwnProperty("contentItem"))
          view = child
      const rows = []
      const titles = []
      for (const child of view.contentItem.children) {
        if (child.hasOwnProperty("thread"))
          rows.push(child)
        else if (child.hasOwnProperty("section") && child.visible)
          titles.push(child)
      }
      rows.sort((a, b) => a.y - b.y)
      checked += rows.length
      for (let i = 1; i < rows.length; i++)
        if (rows[i].y < rows[i - 1].y + rows[i - 1].height) {
          faults++
          console.log("FAULT row", i, "starts at", rows[i].y, "over a row that ends at", rows[i - 1].y + rows[i - 1].height)
        }
      for (const title of titles)
        for (const row of rows)
          if (title.y < row.y + row.height && title.y + title.height > row.y) {
            faults++
            console.log("FAULT title", title.section, "at", title.y, "over a row at", row.y)
          }
    }

    Timer { interval: 300; running: true; onTriggered: { win.arrive(); host.width = 390; host.height = 844 } }
    Timer { id: burst; interval: 1500; running: true; repeat: true; onTriggered: { first.start(); second.start(); third.start(); settle.start() } }
    Timer { id: first; interval: 100; onTriggered: win.change() }
    Timer { id: second; interval: 250; onTriggered: win.change() }
    Timer { id: third; interval: 400; onTriggered: win.change() }
    Timer { id: settle; interval: 1100; onTriggered: win.inspect() }
    Timer { interval: 12000; running: true; onTriggered: { console.log("RESULT", win.checked, win.faults); Qt.quit() } }
  }
}
