pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Time.js" as Time
import "kit/ui"

// LogView is the open conversation as a log: every event, oldest first, a
// line each: when, its kind, what it says in a plain sentence and who, FAILED
// or NEEDS YOU at the right — under a rule naming the day, and one naming each
// run where it begins. Plumbing (run starts and ends, hooks, empty replies)
// is dimmer and hidden until BEHIND THE SCENES is on. The search line keeps
// the rows whose text holds it; chips keep the ones that need you or failed,
// and a picker one agent's. The count
// of rows sits at the filters' right end, or under them when they would not
// fit beside it, and "more" copies the event picked, else the rows shown. A
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
    request: { icon: "people", tone: Theme.warning },
    reply: { icon: "enter", tone: Theme.warning },
    break: { icon: "warning", tone: Theme.error }
  })

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
  signal leave()

  // Whether the line is a question that still waits on the person.
  function waits(line) {
    return line.request !== "" && Omunculus.waiting.some(request => request.id === line.request)
  }

  function matches(line) {
    const wanted = filter.trim().toLowerCase()
    return (!asksOnly || waits(line)) && (!failedOnly || (!line.ok && !line.retried)) && (agent === "" || line.who === agent)
      && (showMinor || !line.minor || line.head !== "")
      && (wanted === "" || [line.kind, line.who, line.run, line.work, line.what].join(" ").toLowerCase().includes(wanted))
  }

  // The rows the filters keep, rebuilt when a filter changes and extended as
  // rows arrive.
  function refilter() {
    shown.clear()
    seen = 0
    extend()
  }

  function extend() {
    if (!filtered)
      return
    const rows = Omunculus.eventLog
    for (; seen < rows.rows.count; seen++) {
      const line = rows.row(seen)
      if (matches(line))
        shown.append(line)
    }
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
    const lines = []
    for (let i = 0; i < source.count; i++) {
      const line = source.get(i)
      lines.push([line.time, line.kind, line.who, short(line.run), short(line.work), line.what].join("\t"))
    }
    Omunculus.copy(lines.join("\n"))
  }

  function back() {
    if (picked !== null)
      picked = null
    else
      leave()
  }

  Component.onCompleted: refilter()
  onFilterChanged: refilter()
  onAsksOnlyChanged: refilter()
  Connections {
    target: Omunculus
    function onWaitingChanged() { if (view.asksOnly) view.refilter() }
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
    }
    // A failure settled as retried leaves the FAILED rows.
    function onDataChanged() {
      if (view.failedOnly)
        view.refilter()
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

    // The filters, the count and the rare actions; the count and the menu
    // go under the chips when all would not fit on one line, so neither
    // covers a chip.
    GridLayout {
      id: filters
      readonly property bool stacked: chips.contentWidth + tally.implicitWidth + menu.implicitWidth + columnSpacing * 2 > width
      Layout.fillWidth: true
      columns: stacked ? 2 : 3
      columnSpacing: Theme.space.gap
      rowSpacing: Theme.space.tight
      ChipStrip {
        id: chips
        Layout.columnSpan: filters.stacked ? 2 : 1
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        Chip { text: "NEEDS YOU"; checked: view.asksOnly; accent: Theme.warning; tip: "the questions waiting on you"; onClicked: view.asksOnly = !view.asksOnly }
        Chip { text: "FAILED"; checked: view.failedOnly; accent: Theme.error; onClicked: view.failedOnly = !view.failedOnly }
        Chip { text: "BEHIND THE SCENES"; checked: view.showMinor; tip: "run starts and ends, hooks, empty replies"; onClicked: view.showMinor = !view.showMinor }
        Dropdown {
          options: [""].concat(Omunculus.eventLog.agents)
          current: view.agent
          emphasized: view.agent !== ""
          describe: option => option === "" ? "ALL AGENTS" : option.toUpperCase()
          onPicked: option => view.agent = option
        }
      }
      Label {
        id: tally
        Layout.maximumWidth: filters.stacked ? Number.POSITIVE_INFINITY : implicitWidth
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: (list.count + (view.filtered ? " of " + Omunculus.eventLog.rows.count : "") + " events").toUpperCase()
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
        elide: Text.ElideRight
      }
      ActionMenu {
        id: menu
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
      spacing: Theme.space.row
      cacheBuffer: 0
      model: view.source
      keyNavigationEnabled: true
      activeFocusOnTab: true
      // At the end when last moved, so a new row keeps it there.
      property bool atEnd: true
      onMovementEnded: atEnd = atYEnd
      onCountChanged: if (atEnd) Qt.callLater(positionViewAtEnd)
      onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0
      Keys.onReturnPressed: if (currentIndex >= 0) view.pick(view.source.get(currentIndex))
      Keys.onEscapePressed: view.back()

      delegate: Item {
        id: row
        required property var model
        required property int index
        readonly property var line: model
        readonly property var kind: view.kinds[model.type] || ({ icon: "more", tone: Theme.dim })
        readonly property bool marked: (view.picked !== null && view.picked.id === model.id) || (ListView.isCurrentItem && list.activeFocus)
        readonly property string status: !model.ok ? (model.retried ? "RETRIED" : "FAILED") : view.waits(model) ? "NEEDS YOU" : ""
        // Its width is that of the longest status, so the agent column aligns.
        TextMetrics {
          id: statusWidth
          text: "NEEDS YOU"
          font.pixelSize: Theme.type.header.size
          font.letterSpacing: Theme.type.header.tracking
        }
        // A failure a later call settled is dim, not red.
        readonly property bool bad: !model.ok && !model.retried

        width: list.width
        height: (model.day !== "" ? Theme.size.rule : 0) + (model.head !== "" ? Theme.size.rule : 0) + box.height

        // The day, then the run it begins.
        Kicker {
          visible: row.model.day !== ""
          width: parent.width
          height: Theme.size.rule
          text: row.model.day
        }
        Kicker {
          visible: row.model.head !== ""
          y: row.model.day !== "" ? Theme.size.rule : 0
          width: parent.width
          height: Theme.size.rule
          text: row.model.head
          tone: Theme.primary
        }

        // A row is one line; plumbing is dimmer and shorter.
        Rectangle {
          id: box
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: Theme.size.stackedRow + (row.model.minor ? 0 : Theme.space.line)
          color: row.marked ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
          border.color: row.marked ? Theme.primary : "transparent"

          RowLayout {
            anchors { fill: parent; leftMargin: Theme.space.cell; rightMargin: Theme.space.cell }
            spacing: Theme.space.gap
            opacity: row.model.minor && !row.marked ? 0.6 : 1
            Label {
              text: row.model.time
              color: Theme.dim
              font.pixelSize: Theme.type.meta.size
            }
            Icon {
              name: row.kind.icon
              size: 10
              color: row.kind.tone
            }
            Label {
              Layout.preferredWidth: Theme.size.control * 1.4
              text: row.model.kind.toUpperCase()
              color: row.kind.tone
              font.pixelSize: Theme.type.header.size
              font.letterSpacing: Theme.type.header.tracking
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: row.model.what
              color: row.bad ? Theme.error : row.model.ok && !row.model.minor ? Theme.foreground : Theme.dim
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            Label {
              visible: row.model.who !== "" && row.model.who !== "harness"
              Layout.maximumWidth: box.width * 0.2
              text: row.model.who
              color: Omunculus.toneOf(row.model.who)
              font.pixelSize: Theme.type.meta.size
              elide: Text.ElideRight
            }
            Label {
              Layout.preferredWidth: statusWidth.advanceWidth
              horizontalAlignment: Text.AlignRight
              text: row.status
              color: row.bad ? Theme.error : row.model.ok ? Theme.warning : Theme.dim
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
        visible: list.count === 0
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
