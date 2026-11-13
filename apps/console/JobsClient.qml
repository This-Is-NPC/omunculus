import QtQuick

// JobsClient is the project's scheduled jobs on the server: the list, kept
// until the project changes, a job's history, the preview of a schedule, and
// the actions on a job. Each action goes through the API; a refusal is told
// as the sentence the server gave, or handed to `failed` when one is given.
QtObject {
  id: root

  // The project's client, a Project.
  property var client: null
  // The jobs the window may read, each with its totals, and whether they were read.
  property var items: []
  property bool loaded: false

  readonly property string base: client ? client.base + "/jobs" : ""

  function path(ref) { return base + "/" + encodeURIComponent(ref) }

  // Reads the list again.
  function load() {
    const on = client.project
    client.call("GET", base, null, false, data => {
      if (on !== client.project)
        return
      items = data.items
      loaded = true
    })
  }

  // A job's newest events, oldest first; `done` gets the list.
  function history(ref, done) {
    const on = client.project
    client.call("GET", path(ref) + "/history?limit=500", null, false, data => {
      if (on === client.project)
        done(data.events)
    })
  }

  // The next fires and the estimated cost of a schedule, `request` as
  // Jobs.previewOf gives it.
  function preview(request, done, failed) {
    const on = client.project
    client.call("POST", base + "/preview", request, true, data => {
      if (on === client.project)
        done(data)
    }, failed)
  }

  // Makes a job; `done` follows once it exists.
  function create(body, done, failed) {
    client.call("POST", base, body, true, () => {
      load()
      done()
    }, failed)
  }

  // Does `action` (edit, duplicate, pause, resume, run or archive) to the job
  // `ref`, `body` its fields; `done` follows once it was done.
  function act(ref, action, body, done, failed) {
    client.call("POST", path(ref) + "/actions/" + action, Object.assign({ channel: "console" }, body), true, () => {
      load()
      if (done)
        done()
    }, failed)
  }

  // A job the window may read, by id or by name.
  function find(ref) { return items.find(job => job.id === ref || job.name === ref) || null }

  readonly property Connections follows: Connections {
    target: root.client
    function onProjectChanged() {
      root.items = []
      root.loaded = false
    }
  }
}
