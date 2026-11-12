pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Events.js" as Events
import "kit/client/LogGroups.js" as LogGroups
import "kit/client/Time.js" as Time
import "kit/client/Tree.js" as Tree
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// LogView is the open conversation as a log: every event a line: when, its
// kind, what it says in a plain sentence and who, FAILED or NEEDS YOU at the
// right. BY LEVEL groups the lines under a header per level of the hierarchy,
// each line's dot in the column of its level; BY WORK puts them under the
// lineage row of their work, on the same lifelines as the tree (LogGroups);
// BY TIME lists them oldest first under a rule naming the day, and one naming
// each run where it begins. Plumbing (run starts and ends, hooks, empty replies)
// is dimmer and hidden until BEHIND THE SCENES is on. The search line keeps
// the rows whose text holds it; chips, each with its count, keep the ones
// that need you or failed, and a picker one agent's; they stay on one line
// that scrolls sideways. The count of rows sits under them, on one line, with
// "more", which copies the event picked, else the rows shown. Under 560 px a row is two lines — when, kind,
// who and status, then what it says in up to three lines — instead of columns. A
// row picked shows its event in a card below, as the server sent it, the
// first 20 KB unless all is asked, its raw type in the card's title. The list follows the newest row while it
// is at the end. `/` goes to the search; Esc there empties it, then goes
// back to the rows; Esc on them closes the event picked, then leaves.
Item {
  id: view

  // Characters of an event shown before "show all".
  readonly property int detailLimit: 20000
  readonly property var kinds: ({
    prompt: { icon: "send", tone: Theme.primary },
    model: { icon: "spark", tone: Theme.secondary },
    tool: { icon: "list", tone: Theme.foreground },
    "start-run": { icon: "play", tone: Theme.success },
    "end-run": { icon: "check", tone: Theme.success },
    question: { icon: "help", tone: Theme.warning },
    decision: { icon: "diamond", tone: Theme.warning },
    permission: { icon: "shield", tone: Theme.warning },
    review: { icon: "spark", tone: Theme.warning },
    reply: { icon: "enter", tone: Theme.warning },
    release: { icon: "check", tone: Theme.warning },
    break: { icon: "warning", tone: Theme.error }
  })

  // How the lines are grouped: "level", "work" or "time".
  property string grouping: "level"
  // What the list shows (LogGroups.group), rebuilt once however many rows or
  // filters changed together.
  property var items: []
  property int events: 0
  readonly property var blank: ({ id: "", type: "", kind: "", ok: true, retried: false, request: "", minor: false, who: "", what: "", time: "", day: "", head: "" })
  property string filter: ""
  property bool asksOnly: false
  property bool failedOnly: false
  property string agent: ""
  property bool showMinor: false
  // The row picked as a plain object, and its event as text.
  property var picked: null
  property string detail: ""
  property bool showAll: false
  readonly property bool filtered: filter.trim() !== "" || asksOnly || failedOnly || agent !== "" || !showMinor
  readonly property var source: filtered ? shown : Omunculus.eventLog.rows
  property int seen: 0
  // How many rows only BEHIND THE SCENES being off keeps out.
  property int hidden: 0
  // What the chips count over every row: {asks, failed, minor}.
  property var counts: ({ asks: 0, failed: 0, minor: 0 })
  signal leave()

  // Whether the line is a question that still waits on the person.
  function waits(line) {
    return line.request !== "" && Omunculus.waiting.some(request => request.id === line.request)
  }

  // Counts again, once however many rows or answers changed together.
  function recount() {
    const rows = Omunculus.eventLog.rows
    counts = Events.tally(rows.count, index => rows.get(index), line => waits(line))
  }

  function matches(line, minor) {
    const wanted = filter.trim().toLowerCase()
    return (!asksOnly || waits(line)) && (!failedOnly || (!line.ok && !line.retried)) && (agent === "" || line.who === agent)
      && (minor || !line.minor || line.head !== "")
      && (wanted === "" || [line.kind, line.who, line.run, line.work, line.what].join(" ").toLowerCase().includes(wanted))
  }

  // The rows the filters keep, rebuilt when a filter changes and extended as
  // rows arrive.
  function refilter() {
    shown.clear()
    seen = 0
    hidden = 0
    extend()
    rebuilding.restart()
  }

  function extend() {
    if (!filtered)
      return
    const rows = Omunculus.eventLog
    for (; seen < rows.rows.count; seen++) {
      const line = rows.row(seen)
      if (matches(line, showMinor))
        shown.append(line)
      else if (matches(line, true))
        hidden++
    }
  }

  function rebuild() {
    const lines = []
    for (let i = 0; i < source.count; i++)
      lines.push(Omunculus.eventLog.plain(source.get(i)))
    events = lines.length
    items = LogGroups.group(grouping, lines, Omunculus.progress)
  }

  Timer {
    id: rebuilding
    interval: 150
    onTriggered: view.rebuild()
  }
  onGroupingChanged: rebuilding.restart()
  Connections {
    target: Omunculus
    function onProgressChanged() { rebuilding.restart() }
  }

  function short(id) { return id ? id.slice(0, 8) : "" }

  function pick(line) {
    picked = { id: line.id, type: line.type, at: line.at, raw: line.raw }
    showAll = false
    try {
      detail = JSON.stringify(JSON.parse(line.raw), null, 2)
    } catch (error) {
      detail = line.raw
    }
  }

  function focusFilter() { filterBox.forceActiveFocus() }

  // The event picked, whole, or the rows shown, a line each.
  function copy() {
    if (picked !== null) {
      Omunculus.copy(detail)
      return
    }
    Omunculus.copy(items.filter(item => item.kind === "line").map(item => item.line)
      .map(line => [line.time, line.kind, line.who, short(line.run), short(line.work), line.what].join("\t")).join("\n"))
  }

  function back() {
    if (picked !== null)
      picked = null
    else
      leave()
  }

  Component.onCompleted: {
    refilter()
    rebuild()
    recount()
  }
  onFilterChanged: refilter()
  onAsksOnlyChanged: refilter()
  Connections {
    target: Omunculus
    function onWaitingChanged() {
      if (view.asksOnly)
        view.refilter()
      Qt.callLater(view.recount)
    }
  }
  onFailedOnlyChanged: refilter()
  onAgentChanged: refilter()
  onShowMinorChanged: refilter()

  ListModel { id: shown }

  Connections {
    target: Omunculus.eventLog.rows
    function onCountChanged() {
      if (Omunculus.eventLog.rows.count < view.seen)
        view.refilter()
      else
        view.extend()
      rebuilding.restart()
      Qt.callLater(view.recount)
    }
    // A failure settled as retried leaves the FAILED rows.
    function onDataChanged() {
      if (view.failedOnly)
        view.refilter()
      rebuilding.restart()
      Qt.callLater(view.recount)
    }
  }

  Keys.onEscapePressed: back()
  Keys.onPressed: event => {
    if (event.text !== "/")
      return
    focusFilter()
    event.accepted = true
  }
  onActiveFocusChanged: if (activeFocus) list.forceActiveFocus()

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    FilterBox {
      id: filterBox
      Layout.fillWidth: true
      placeholderText: "Search kinds, agents and text…  /"
      onApplied: value => view.filter = value
      onLeave: list.forceActiveFocus()
    }

    ChipStrip {
      Layout.fillWidth: true
      Chip { text: "BY LEVEL"; checked: view.grouping === "level"; tip: "the lines under the level of the hierarchy that made them"; onClicked: view.grouping = "level" }
      Chip { text: "BY WORK"; checked: view.grouping === "work"; tip: "the lines under their work, in the order of the tree"; onClicked: view.grouping = "work" }
      Chip { text: "BY TIME"; checked: view.grouping === "time"; tip: "every line, oldest first"; onClicked: view.grouping = "time" }
    }

    // The filters, on one line that scrolls, then the count and the rare actions.
    ChipStrip {
      Layout.fillWidth: true
      Chip { text: "NEEDS YOU  " + view.counts.asks; checked: view.asksOnly; accent: Theme.warning; tip: "the questions waiting on you"; onClicked: view.asksOnly = !view.asksOnly }
      Chip { text: "FAILED  " + view.counts.failed; checked: view.failedOnly; accent: Theme.error; onClicked: view.failedOnly = !view.failedOnly }
      Chip { text: "BEHIND THE SCENES  " + view.counts.minor; checked: view.showMinor; tip: "run starts and ends, hooks, empty replies"; onClicked: view.showMinor = !view.showMinor }
      Dropdown {
        options: [""].concat(Omunculus.eventLog.agents)
        current: view.agent
        emphasized: view.agent !== ""
        describe: option => option === "" ? "ALL AGENTS" : option.toUpperCase()
        onPicked: option => view.agent = option
      }
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap
      Label {
        id: tally
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: (view.events + (view.filtered ? " of " + Omunculus.eventLog.rows.count : "") + " events"
          + (view.hidden > 0 ? " · " + view.hidden + (Breakpoints.tight(view.width) ? " hidden" : " behind the scenes hidden") : "")).toUpperCase()
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
        elide: Text.ElideRight
      }
      ActionMenu {
        items: [{ id: "copy", icon: "copy", text: view.picked !== null ? "COPY EVENT" : "COPY LOG" }]
        tip: "copy the event picked, else the rows shown"
        onChosen: view.copy()
      }
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      topMargin: 1
      bottomMargin: 1
      cacheBuffer: 0
      model: view.items
      keyNavigationEnabled: true
      activeFocusOnTab: true
      // At the end when last moved, so a new row keeps it there.
      property bool atEnd: true
      onMovementEnded: atEnd = atYEnd
      onCountChanged: if (atEnd) Qt.callLater(positionViewAtEnd)
      onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0
      Keys.onReturnPressed: if (currentIndex >= 0 && view.items[currentIndex].kind === "line") view.pick(view.items[currentIndex].line)
      Keys.onEscapePressed: view.back()

      delegate: Item {
        id: row
        required property var modelData
        required property int index
        // A header has no line: the blank one reads as an empty row.
        readonly property var line: modelData.line || view.blank
        readonly property bool isLine: modelData.kind === "line"
        readonly property bool timed: modelData.kind === "line" && modelData.col < 0
        readonly property real unit: list.width < 560 ? Theme.size.mark : Theme.size.gutter
        // Where the line's own columns start, right of its lifeline.
        readonly property real indent: isLine && modelData.col >= 0 ? (modelData.col + 1) * unit : 0
        readonly property var kind: view.kinds[line.type === "request" ? line.kind : line.type] || ({ icon: "more", tone: Theme.dim })
        readonly property bool marked: isLine && ((view.picked !== null && view.picked.id === line.id) || (ListView.isCurrentItem && list.activeFocus))
        readonly property string status: !line.ok ? (line.retried ? "RETRIED" : "FAILED") : view.waits(line) ? "NEEDS YOU" : ""
        // Its width is that of the longest status, so the agent column aligns.
        TextMetrics {
          id: statusWidth
          text: "NEEDS YOU"
          font.pixelSize: Theme.type.header.size
          font.letterSpacing: Theme.type.header.tracking
        }
        // The kind column holds the longest single kind whole ("CONVERSATION").
        TextMetrics {
          id: kindWidth
          text: "CONVERSATION"
          font.pixelSize: Theme.type.header.size
          font.letterSpacing: Theme.type.header.tracking
        }
        // A failure a later call settled is dim, not red.
        readonly property bool bad: !line.ok && !line.retried
        // Narrow, a row is two lines, not columns.
        readonly property bool stacked: list.width < 560

        width: list.width
        height: modelData.kind === "level" ? Theme.size.rule : modelData.kind === "work" ? lineage.implicitHeight
          : (row.timed && line.day !== "" ? Theme.size.rule : 0) + (row.timed && line.head !== "" ? Theme.size.rule : 0) + box.height + Theme.space.row

        // The level a group of lines is of, or the work it belongs to.
        Kicker {
          visible: row.modelData.kind === "level"
          width: parent.width
          height: Theme.size.rule
          text: row.modelData.text || ""
        }
        LineageRow {
          id: lineage
          visible: row.modelData.kind === "work"
          width: parent.width
          depth: row.modelData.row ? row.modelData.row.depth : 0
          rails: row.modelData.row ? row.modelData.row.rails : []
          last: row.modelData.row ? row.modelData.row.last : false
          stem: row.modelData.row ? row.modelData.row.stem : false
          unit: row.unit
          linked: false
          agent: front ? row.modelData.row.front.agent : node ? node.agent : ""
          tone: Omunculus.toneOf(agent)
          title: front ? row.modelData.row.front.doing : node ? node.title : ""
          meta: row.modelData.kind === "work" ? row.modelData.count + (row.modelData.count === 1 ? " event" : " events") : ""
          state: look ? look.state : ""
          stateText: look ? look.text : ""
          readonly property bool front: !!row.modelData.row && row.modelData.row.kind === "front"
          readonly property var node: row.modelData.row && row.modelData.row.kind === "work" ? row.modelData.row.node : null
          readonly property var look: front ? Tree.frontState(row.modelData.row.front) : node ? Tree.stateOf(node) : null
        }
        // The lifeline of a line, and its mark at its level.
        Lifeline {
          visible: row.isLine && row.modelData.col >= 0
          depth: row.isLine ? row.modelData.col : 0
          rails: row.isLine ? row.modelData.rails : []
          line: row.isLine && row.modelData.through ? "through" : "none"
          unit: row.unit
          markY: box.y + box.height / 2
          marked: true
          markTone: Omunculus.toneOf(row.line.who)
        }

        // The day, then the run it begins.
        Kicker {
          visible: row.timed && row.line.day !== ""
          width: parent.width
          height: Theme.size.rule
          text: row.line.day
        }
        Kicker {
          visible: row.timed && row.line.head !== ""
          y: row.timed && row.line.day !== "" ? Theme.size.rule : 0
          width: parent.width
          height: Theme.size.rule
          text: row.line.head
          tone: Theme.primary
        }

        // A row is one line; plumbing is dimmer and shorter.
        Rectangle {
          id: box
          visible: row.isLine
          anchors { left: parent.left; right: parent.right; leftMargin: row.indent; bottom: parent.bottom; bottomMargin: Theme.space.row }
          height: row.stacked ? lines.implicitHeight + Theme.space.tight * 2 : Theme.size.stackedRow + (row.line.minor ? 0 : Theme.space.line)
          color: row.marked ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
          border.color: row.marked ? Theme.primary : "transparent"

          // Narrow: when, kind, who and status, then what it says.
          ColumnLayout {
            id: lines
            visible: row.stacked
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.cell; rightMargin: Theme.space.cell }
            spacing: Theme.space.row
            opacity: row.line.minor && !row.marked ? 0.6 : 1
            RowLayout {
              Layout.fillWidth: true
              spacing: Theme.space.gap
              Label {
                text: row.line.time
                color: Theme.dim
                font.pixelSize: Theme.type.meta.size
              }
              Icon {
                name: row.bad ? "warning" : row.kind.icon
                size: 10
                color: row.bad ? Theme.error : row.kind.tone
              }
              Label {
                text: row.line.kind.toUpperCase()
                color: row.bad ? Theme.error : row.kind.tone
                font.pixelSize: Theme.type.header.size
                font.letterSpacing: Theme.type.header.tracking
              }
              Label {
                visible: row.line.who !== "" && row.line.who !== "harness"
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: row.line.who
                color: Omunculus.toneOf(row.line.who)
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideRight
              }
              Item { visible: row.line.who === "" || row.line.who === "harness"; Layout.fillWidth: true }
              Label {
                text: row.status
                color: row.bad ? Theme.error : row.line.ok ? Theme.warning : Theme.dim
                font.pixelSize: Theme.type.header.size
                font.letterSpacing: Theme.type.header.tracking
              }
            }
            Label {
              Layout.fillWidth: true
              text: row.line.what
              color: row.bad ? Theme.error : row.line.ok && !row.line.minor ? Theme.foreground : Theme.dim
              font.pixelSize: Theme.type.body.size
              wrapMode: Text.Wrap
              maximumLineCount: row.line.minor ? 1 : 3
              elide: Text.ElideRight
            }
          }

          RowLayout {
            visible: !row.stacked
            anchors { fill: parent; leftMargin: Theme.space.cell; rightMargin: Theme.space.cell }
            spacing: Theme.space.gap
            opacity: row.line.minor && !row.marked ? 0.6 : 1
            Label {
              text: row.line.time
              color: Theme.dim
              font.pixelSize: Theme.type.meta.size
            }
            Icon {
              name: row.bad ? "warning" : row.kind.icon
              size: 10
              color: row.bad ? Theme.error : row.kind.tone
            }
            Label {
              Layout.preferredWidth: kindWidth.advanceWidth
              text: row.line.kind.toUpperCase()
              color: row.bad ? Theme.error : row.kind.tone
              font.pixelSize: Theme.type.header.size
              font.letterSpacing: Theme.type.header.tracking
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: row.line.what
              color: row.bad ? Theme.error : row.line.ok && !row.line.minor ? Theme.foreground : Theme.dim
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            Label {
              visible: row.line.who !== "" && row.line.who !== "harness"
              Layout.maximumWidth: box.width * 0.2
              text: row.line.who
              color: Omunculus.toneOf(row.line.who)
              font.pixelSize: Theme.type.meta.size
              elide: Text.ElideRight
            }
            Label {
              Layout.preferredWidth: statusWidth.advanceWidth
              horizontalAlignment: Text.AlignRight
              text: row.status
              color: row.bad ? Theme.error : row.line.ok ? Theme.warning : Theme.dim
              font.pixelSize: Theme.type.header.size
              font.letterSpacing: Theme.type.header.tracking
            }
          }

          MouseArea {
            id: pointer
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              list.currentIndex = row.index
              list.forceActiveFocus()
              view.pick(row.line)
            }
          }
        }
      }

      // Beside the rows' content, centred while there are none.
      Label {
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.page }
        visible: view.items.length === 0
        horizontalAlignment: Text.AlignHCenter
        text: Omunculus.replaying ? "reading the conversation" : "no event matches"
        color: Theme.dim
        font.pixelSize: Theme.type.tab.size
      }
    }

    // The event picked, its tools at the top right.
    Panel {
      id: card
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(view.height * 0.4, body.implicitHeight + stamp.implicitHeight + Theme.size.strip + Theme.space.inset * 2)
      visible: view.picked !== null
      title: view.picked ? view.picked.type : ""
      tools: [
        Chip {
          visible: view.detail.length > view.detailLimit && !view.showAll
          text: "SHOW ALL"
          tip: "the event whole, past its first 20 KB"
          onClicked: view.showAll = true
        },
        IconButton { name: "copy"; tip: "copy the event"; onClicked: view.copy() },
        IconButton { name: "close"; tip: "close  Esc"; onClicked: view.picked = null }
      ]

      ColumnLayout {
        anchors.fill: parent
        spacing: Theme.space.tight
        Label {
          id: stamp
          Layout.fillWidth: true
          text: view.picked ? Time.full(view.picked.at) + (card.width < 480 ? "" : "  ·  UTC " + view.picked.at) : ""
          color: Theme.dim
          font.pixelSize: Theme.type.meta.size
          elide: Text.ElideRight
        }
        Flickable {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          contentHeight: body.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          Label {
            id: body
            width: parent.width
            text: view.showAll ? view.detail : view.detail.slice(0, view.detailLimit)
            color: Theme.foreground
            font.pixelSize: Theme.type.tab.size
            wrapMode: Text.WrapAnywhere
          }
        }
      }
    }
  }
}
