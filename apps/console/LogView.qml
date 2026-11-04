pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Time.js" as Time
import "kit/ui"

// LogView is the open conversation as a log: every event, oldest first, a row
// each — when, what kind, who, and what it says on one line — under a title
// where a run begins. The filter box keeps the rows whose text holds it, and
// chips keep the ones that ask the person, the failed ones, one agent's, or
// one depth's. A row picked shows its event below, as the server sent it, the
// first 20 KB unless all is asked. The list follows the newest row while it is
// at the end. `/` goes to the filter; Esc there empties it, then goes back to
// the rows; Esc on them closes the event picked, then leaves.
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
  property int depth: -1
  // The row picked as a plain object, and its event as text.
  property var picked: null
  property string detail: ""
  property bool showAll: false
  readonly property bool filtered: filter.trim() !== "" || asksOnly || failedOnly || agent !== "" || depth >= 0
  readonly property var source: filtered ? shown : Omunculus.eventLog.rows
  property int seen: 0
  signal leave()

  function matches(line) {
    const wanted = filter.trim().toLowerCase()
    return (!asksOnly || line.asks) && (!failedOnly || !line.ok) && (agent === "" || line.who === agent)
      && (depth < 0 || line.depth === depth)
      && (wanted === "" || [line.type, line.who, line.run, line.work, line.what].join(" ").toLowerCase().includes(wanted))
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
      lines.push([line.time, line.type, line.who, short(line.run), short(line.work), line.what].join("\t"))
    }
    Omunculus.copy(lines.join("\n"))
  }

  function back() {
    if (picked !== null)
      picked = null
    else
      leave()
  }

  onFilterChanged: refilter()
  onAsksOnlyChanged: refilter()
  onFailedOnlyChanged: refilter()
  onAgentChanged: refilter()
  onDepthChanged: refilter()

  ListModel { id: shown }

  Connections {
    target: Omunculus.eventLog.rows
    function onCountChanged() {
      if (Omunculus.eventLog.rows.count < view.seen)
        view.refilter()
      else
        view.extend()
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
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      FilterBox {
        id: filterBox
        Layout.fillWidth: true
        placeholderText: "filter by kind, agent, run, work or text"
        onApplied: value => view.filter = value
        onLeave: list.forceActiveFocus()
      }
      Label {
        text: list.count + (view.filtered ? " of " + Omunculus.eventLog.rows.count : "") + " events"
        color: Theme.dim
        font.pixelSize: 11
      }
    }

    Flow {
      Layout.fillWidth: true
      spacing: 6
      Chip { text: "ASKS ME"; checked: view.asksOnly; onClicked: view.asksOnly = !view.asksOnly }
      Chip { text: "FAILED"; checked: view.failedOnly; onClicked: view.failedOnly = !view.failedOnly }
      Repeater {
        model: Omunculus.eventLog.agents
        delegate: Chip {
          required property string modelData
          text: modelData.toUpperCase()
          checked: view.agent === modelData
          onClicked: view.agent = checked ? "" : modelData
        }
      }
      Repeater {
        model: Omunculus.eventLog.depths.length > 1 ? Omunculus.eventLog.depths : []
        delegate: Chip {
          required property int modelData
          text: "DEPTH " + modelData
          checked: view.depth === modelData
          onClicked: view.depth = checked ? -1 : modelData
        }
      }
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      topMargin: 1
      bottomMargin: 1
      spacing: 2
      cacheBuffer: 0
      model: view.source
      keyNavigationEnabled: true
      activeFocusOnTab: true
      // At the end when last moved, so a new row keeps it there.
      property bool atEnd: true
      onMovementEnded: atEnd = atYEnd
      onCountChanged: if (atEnd) Qt.callLater(positionViewAtEnd)
      onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0
      Keys.onReturnPressed: if (currentItem) view.pick(currentItem.line)
      Keys.onEscapePressed: view.back()

      delegate: Item {
        id: row
        required property var model
        required property int index
        readonly property var line: model
        readonly property var kind: view.kinds[model.type] || ({ icon: "more", tone: Theme.dim })
        readonly property bool marked: (view.picked !== null && view.picked.id === model.id) || (ListView.isCurrentItem && list.activeFocus)
        readonly property real cell: Math.max(0, width - 24)

        width: list.width
        height: (model.day !== "" ? 26 : 0) + (model.head !== "" ? 26 : 0) + 28

        Label {
          visible: row.model.day !== ""
          x: 12
          width: parent.width - 24
          height: 22
          verticalAlignment: Text.AlignBottom
          text: row.model.day
          color: Theme.dim
          font.pixelSize: 11
          font.letterSpacing: 1
        }

        Label {
          visible: row.model.head !== ""
          y: row.model.day !== "" ? 26 : 0
          x: 12
          width: parent.width - 24
          height: 22
          verticalAlignment: Text.AlignBottom
          text: row.model.head
          color: Theme.primary
          font.pixelSize: 11
          font.letterSpacing: 1
          elide: Text.ElideRight
        }

        Rectangle {
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: 28
          color: row.marked ? Theme.highlight : "transparent"
          border.color: row.marked ? Theme.primary : Theme.line

          Label {
            x: 12
            width: row.cell * 0.12
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: row.model.time
            color: Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          Icon {
            x: 12 + row.cell * 0.12
            anchors.verticalCenter: parent.verticalCenter
            name: row.kind.icon
            size: 12
            color: row.kind.tone
          }
          Label {
            x: 12 + row.cell * 0.12 + 20
            width: row.cell * 0.12 - 20
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: row.model.type
            color: row.kind.tone
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          Label {
            x: 12 + row.cell * 0.24
            width: row.cell * 0.14
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: row.model.who
            color: row.model.who === "" ? Theme.dim : Omunculus.toneOf(row.model.who)
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          Label {
            x: 12 + row.cell * 0.38
            width: row.cell * 0.62
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: row.model.what
            color: row.model.ok ? Theme.foreground : Theme.error
            font.pixelSize: 11
            elide: Text.ElideRight
          }
          MouseArea {
            anchors.fill: parent
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
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
        visible: list.count === 0
        horizontalAlignment: Text.AlignHCenter
        text: Omunculus.replaying ? "reading the conversation" : "no event matches"
        color: Theme.dim
        font.pixelSize: 11
      }
    }

    // The event picked.
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(view.height * 0.4, body.implicitHeight + head.implicitHeight + 30)
      visible: view.picked !== null
      color: "transparent"
      border.color: Theme.line

      RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10; leftMargin: 12 }
        spacing: 10
        Label { text: view.picked ? view.picked.type.toUpperCase() : ""; color: Theme.primary; font.pixelSize: 11; font.letterSpacing: 2 }
        Label { Layout.fillWidth: true; text: view.picked ? Time.full(view.picked.at) + "  ·  UTC " + view.picked.at : ""; color: Theme.dim; font.pixelSize: 11 }
        Chip {
          visible: view.detail.length > view.detailLimit && !view.showAll
          text: "SHOW ALL"
          onClicked: view.showAll = true
        }
        IconButton { name: "copy"; tip: "copy the event"; onClicked: view.copy() }
        IconButton { name: "close"; tip: "close (Esc)"; onClicked: view.picked = null }
      }

      Flickable {
        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 10; leftMargin: 12 }
        clip: true
        contentHeight: body.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Label {
          id: body
          width: parent.width
          text: view.showAll ? view.detail : view.detail.slice(0, view.detailLimit)
          color: Theme.foreground
          font.pixelSize: 11
          wrapMode: Text.WrapAnywhere
        }
      }
    }
  }
}
