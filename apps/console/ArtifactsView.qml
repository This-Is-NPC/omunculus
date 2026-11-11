pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Artifacts.js" as Artifacts
import "kit/client/Time.js" as Time
import "kit/ui"

// ArtifactsView lists the documents the conversation's agents made: a section
// per artifact, headed by its title and what it is, a row per version under
// it, oldest first, with its size, by whom and when it was written; the media
// type is in a row's tooltip. Enter, or a click, opens that version. It reads
// them each time it comes on screen. Esc leaves.
FocusScope {
  id: view

  // Whether the page is on screen.
  property bool shown: false
  signal leave()

  property var items: []
  property bool loading: false

  // The versions of every artifact, each with the artifact it is of.
  readonly property var versions: [].concat(...items.map(artifact => artifact.versions.map(version => ({
    id: artifact.name + "@" + version.version, name: artifact.name,
    group: Artifacts.heading(artifact), version: version
  }))))

  function load() {
    const on = Omunculus.conversationId
    if (on === "")
      return
    loading = true
    Omunculus.client.call("GET", Omunculus.base + "/conversations/" + on + "/artifacts", null, false, data => {
      if (on !== Omunculus.conversationId)
        return
      items = data.items
      loading = false
    }, () => { loading = false })
  }

  // A size as a person reads it.
  function size(bytes) {
    return bytes < 1024 ? bytes + " B" : bytes < 1048576 ? (bytes / 1024).toFixed(1) + " KB" : (bytes / 1048576).toFixed(1) + " MB"
  }

  onShownChanged: if (shown) load()
  Component.onCompleted: if (shown) load()
  Connections {
    target: Omunculus
    function onConversationIdChanged() {
      view.items = []
      if (view.shown)
        view.load()
    }
  }

  Keys.onEscapePressed: leave()
  onActiveFocusChanged: if (activeFocus) table.focusRows()

  DataTable {
    id: table
    anchors.fill: parent
    active: view.activeFocus
    rows: view.versions
    section: "group"
    loading: view.loading && view.items.length === 0
    columns: [{ title: "Version", weight: 0.15 }, { title: "Size", weight: 0.2 }, { title: "By", weight: 0.25 }, { title: "Written", weight: 0.4 }]
    cells: entry => ["v" + entry.version.version, view.size(entry.version.bytes), entry.version.by || "", Time.clock(entry.version.at, Date.now())]
    tip: entry => entry.version.media_type || ""
    stacked: [[0], [1, 2, 3]]
    emptyText: "No document was made in this conversation."
    onOpened: entry => Omunculus.openArtifact(entry.name, entry.version)
    onBackRequested: view.leave()
  }
}
