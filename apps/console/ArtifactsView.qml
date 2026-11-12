pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Artifacts.js" as Artifacts
import "kit/client/Time.js" as Time
import "kit/client/Tree.js" as Tree
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints

// ArtifactsView lists the documents the conversation's agents made, BY WORK
// or BY NAME. By work, each work that made one is a lineage row, as in the
// tree, and its files hang under it with their size and when they were
// written; the agent that talks with the person holds those made outside any
// work. By name, a section per artifact, headed by its title and what it is,
// a row per version under it, oldest first, with its size, by whom and when it
// was written; the media type is in a row's tooltip. Enter, or a click, opens
// the file or version. It reads them each time it comes on screen. Esc leaves.
FocusScope {
  id: view

  // Whether the page is on screen.
  property bool shown: false
  signal leave()

  property var items: []
  property bool loading: false
  // "work" or "name".
  property string by: "work"

  // The versions of every artifact, each with the artifact it is of.
  readonly property var versions: [].concat(...items.map(artifact => artifact.versions.map(version => ({
    id: artifact.name + "@" + version.version, name: artifact.name,
    group: Artifacts.heading(artifact), version: version
  }))))

  // The works that made a file, as the tree shows them, with their files.
  readonly property var works: {
    const flat = Omunculus.progress ? Omunculus.progress.flat : []
    const opened = {}
    for (const node of flat)
      opened[node.work] = true
    return Artifacts.byWork(Tree.rows(Omunculus.progress, opened, Artifacts.kept(flat, view.versions)), view.versions)
  }

  function open(item) {
    if (item.kind !== "work")
      Omunculus.openArtifact(item.name, item.version)
  }

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
  onActiveFocusChanged: if (activeFocus) { if (by === "work") list.forceActiveFocus(); else table.focusRows() }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    ChipStrip {
      Layout.fillWidth: true
      Chip { text: "BY WORK"; checked: view.by === "work"; tip: "each work with the files it made"; onClicked: view.by = "work" }
      Chip { text: "BY NAME"; checked: view.by === "name"; tip: "each file with its versions"; onClicked: view.by = "name" }
    }

    ListView {
      id: list
      visible: view.by === "work"
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: view.works
      keyNavigationEnabled: true
      activeFocusOnTab: true
      readonly property bool stacked: width < 560
      readonly property real unit: Breakpoints.tight(width) ? Theme.size.mark : Theme.size.gutter
      Keys.onEscapePressed: view.leave()
      Keys.onReturnPressed: if (currentIndex >= 0) view.open(view.works[currentIndex])
      onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0

      delegate: Item {
        id: item
        required property var modelData
        required property int index
        readonly property bool work: modelData.kind === "work"
        readonly property var row: modelData.row
        readonly property bool front: !!row && row.kind === "front"
        readonly property var node: row && row.kind === "work" ? row.node : null
        readonly property var look: front ? Tree.frontState(row.front) : node ? Tree.stateOf(node) : null
        readonly property real room: width - Theme.space.cell * 2

        width: list.width
        height: work ? lineage.implicitHeight : (list.stacked ? stack.implicitHeight : Theme.size.rule) + Theme.space.row

        Rectangle {
          anchors.fill: parent
          visible: !item.work && ListView.isCurrentItem && list.activeFocus
          color: Theme.highlight
        }
        LineageRow {
          id: lineage
          visible: item.work
          width: parent.width
          depth: item.row ? item.row.depth : 0
          rails: item.row ? item.row.rails : []
          last: item.row ? item.row.last : false
          stem: item.work && (item.modelData.files > 0 || item.row.stem)
          unit: list.unit
          linked: false
          agent: item.front ? item.row.front.agent : item.node ? item.node.agent : ""
          tone: Omunculus.toneOf(agent)
          title: item.front ? item.row.front.doing : item.node ? item.node.title : ""
          meta: item.work ? item.modelData.files + (item.modelData.files === 1 ? " file" : " files") : ""
          state: item.look ? item.look.state : ""
          stateText: item.look ? item.look.text : ""
        }
        Lifeline {
          visible: !item.work && item.modelData.kind === "file"
          depth: item.row ? item.row.depth + 1 : 0
          rails: item.row && item.row.depth > 0 ? item.row.rails.concat([!item.row.last]) : []
          line: "elbow"
          last: !!item.modelData.last
          unit: list.unit
          origin: 0
          markY: item.height / 2
        }
        MouseArea {
          anchors.fill: parent
          visible: !item.work
          onClicked: { list.currentIndex = item.index; list.forceActiveFocus(); view.open(item.modelData) }
        }
        // Wide: one line of columns.
        Item {
          visible: !item.work && !list.stacked
          anchors.fill: parent
          readonly property real start: (item.row ? item.row.depth + 2 : 0) * list.unit
          Label {
            x: parent.start
            width: item.room * 0.6 - parent.start
            anchors.verticalCenter: parent.verticalCenter
            text: item.modelData.name
            color: Theme.foreground
            font.pixelSize: Theme.type.body.size
            elide: Text.ElideRight
          }
          Label {
            x: Theme.space.cell + item.room * 0.6
            anchors.verticalCenter: parent.verticalCenter
            text: item.modelData.version ? view.size(item.modelData.version.bytes) : ""
            color: Theme.dim
            font.pixelSize: Theme.type.meta.size
          }
          Label {
            x: Theme.space.cell + item.room * 0.8
            anchors.verticalCenter: parent.verticalCenter
            text: item.modelData.version ? Time.clock(item.modelData.version.at, Date.now()) : ""
            color: Theme.dim
            font.pixelSize: Theme.type.meta.size
          }
        }
        // Narrow: the name, then its size and time.
        ColumnLayout {
          id: stack
          visible: !item.work && list.stacked
          x: (item.row ? item.row.depth + 2 : 0) * list.unit
          y: Theme.space.tight
          width: item.width - x - Theme.space.cell
          spacing: Theme.space.row
          Label {
            Layout.fillWidth: true
            text: item.modelData.name
            color: Theme.foreground
            font.pixelSize: Theme.type.body.size
            elide: Text.ElideRight
          }
          Label {
            Layout.fillWidth: true
            text: item.modelData.version ? [view.size(item.modelData.version.bytes), Time.clock(item.modelData.version.at, Date.now())].join(Theme.type.meta.separator) : ""
            color: Theme.dim
            font.pixelSize: Theme.type.meta.size
            elide: Text.ElideRight
          }
        }
      }
    }

    Label {
      visible: view.by === "work" && view.works.length === 0
      Layout.fillWidth: true
      text: "No document was made in this conversation."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
    }

    DataTable {
      id: table
      visible: view.by === "name"
      Layout.fillWidth: true
      Layout.fillHeight: true
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
}
