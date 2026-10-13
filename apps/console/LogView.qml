pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// LogView is the open conversation as a log: every event, oldest first, a row
// each — when, what kind, who, its run and work, and what it says on one line.
// A filter keeps the rows whose text holds it; a row picked shows the whole
// event below, as the server sent it. The table follows the newest row while
// it is at the end.
Item {
  id: view

  property string filter: ""
  property var picked: null
  signal leave()

  readonly property var rows: {
    const wanted = filter.trim().toLowerCase()
    if (wanted === "")
      return Omunculus.log
    return Omunculus.log.filter(line => [line.type, line.who, line.run, line.work, line.what].join(" ").toLowerCase().includes(wanted))
  }

  function short(id) { return id ? id.slice(0, 8) : "" }

  Keys.onEscapePressed: picked !== null ? picked = null : view.leave()
  onActiveFocusChanged: if (activeFocus) table.forceActiveFocus()

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      TextBox {
        Layout.fillWidth: true
        dense: true
        placeholderText: "filter by kind, agent, run, work or text"
        onTextEdited: view.filter = text
      }
      Label {
        text: view.rows.length + (view.filter.trim() ? " of " + Omunculus.log.length : "") + " events"
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 1
      }
    }

    DataTable {
      id: table
      Layout.fillWidth: true
      Layout.fillHeight: true
      active: view.visible
      rows: view.rows
      rowHeight: 30
      followsEnd: true
      columns: [
        { title: "time", weight: 0.11 },
        { title: "kind", weight: 0.09 },
        { title: "who", weight: 0.1 },
        { title: "run", weight: 0.08 },
        { title: "work", weight: 0.08 },
        { title: "what", weight: 0.54 }
      ]
      cells: line => [line.time, line.type, line.who, view.short(line.run), view.short(line.work), line.what]
      tone: (line, column) => column === 1
        ? ({ prompt: Theme.primary, model: Theme.secondary, tool: Theme.foreground, "start-run": Theme.success, "end-run": Theme.success,
          request: Theme.warning, reply: Theme.warning, break: Theme.error })[line.type] || Theme.dim
        : column === 2 && line.who ? (line.who === "you" ? Theme.primary : Omunculus.toneOf(line.who))
        : column === 5 && line.type === "tool" && line.event.body && line.event.body.ok === false ? Theme.error
        : column === 0 || column === 3 || column === 4 ? Theme.dim
        : ""
      stacked: [[0, 1, 2], [5]]
      selectedId: view.picked ? view.picked.id : ""
      emptyText: Omunculus.replaying ? "reading the conversation" : "no event matches"
      onOpened: line => view.picked = line
      onBackRequested: view.leave()
    }

    // The event picked, whole.
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(view.height * 0.4, detail.implicitHeight + head.implicitHeight + 30)
      visible: view.picked !== null
      color: "transparent"
      border.color: Theme.line

      RowLayout {
        id: head
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10; leftMargin: 12 }
        spacing: 10
        Label { text: view.picked ? view.picked.type.toUpperCase() : ""; color: Theme.primary; font.pixelSize: 10; font.letterSpacing: 2 }
        Label { Layout.fillWidth: true; text: view.picked ? view.picked.at : ""; color: Theme.dim; font.pixelSize: 10 }
        IconButton { name: "copy"; tip: "copy the event"; onClicked: Omunculus.copy(detail.text) }
        IconButton { name: "close"; tip: "close (Esc)"; onClicked: view.picked = null }
      }

      Flickable {
        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: 10; leftMargin: 12 }
        clip: true
        contentHeight: detail.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        Label {
          id: detail
          width: parent.width
          text: view.picked ? JSON.stringify(view.picked.event, null, 2) : ""
          color: Theme.foreground
          font.pixelSize: 11
          wrapMode: Text.WrapAnywhere
        }
      }
    }
  }
}
