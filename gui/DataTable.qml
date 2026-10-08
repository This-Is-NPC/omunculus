pragma ComponentBehavior: Bound
import QtQuick

// DataTable lists records as rows of columns under a header; below 700 px each
// row stacks its cells into lines instead. A row opens on click or Enter; ↑/↓
// move, Delete asks to remove it, Esc asks to go back. Each row may carry tools
// on its right, from `tools` (its root gets the row's record as `entry`): Tab
// reaches those of the selected row only. Rows may also carry a status cell.
Item {
  id: table

  // {title, weight}: the weights of all columns add up to 1.
  property var columns: []
  property var rows: []
  // The cell texts of a record, one per column.
  property var cells: entry => []
  // A cell's colour, or "" for the usual one (the first column reads brighter).
  property var tone: (entry, column) => ""
  // The columns shown on each line of a stacked row.
  property var stacked: [[0]]
  // The column shown at the top right of a stacked row, or -1.
  property int status: -1
  property Component tools
  property real toolsWidth: 0
  // A record that steps back, as when it cannot be picked.
  property var dimmed: entry => false
  property var idOf: entry => entry.id
  property string selectedId: ""
  property string emptyText
  property bool active: false
  readonly property bool compact: width < 700
  // Below this a row shows its tools only when pointed at or selected, so its
  // text keeps the room.
  readonly property bool narrow: width < 360
  readonly property int rowHeight: compact ? 22 + stacked.length * 20 : 52
  readonly property int headerHeight: compact ? 0 : 32

  signal opened(var entry)
  signal removeRequested(var entry)
  signal backRequested()

  implicitHeight: headerHeight + (compact ? 0 : 10)
    + Math.max(1, rows.length) * rowHeight + Math.max(0, rows.length - 1) * list.spacing
  onActiveChanged: if (active) list.forceActiveFocus()
  onRowsChanged: if (active) Qt.callLater(() => table.reveal())

  // Decode the rows in view, as the view comes in or its records change.
  function reveal() {
    const first = Math.max(0, Math.floor(list.contentY / (rowHeight + list.spacing)) - 1)
    const last = Math.min(list.count, first + Math.ceil(list.height / (rowHeight + list.spacing)) + 3)
    for (let i = first; i < last; i++) {
      const item = list.itemAtIndex(i)
      if (item)
        item.reveal()
    }
  }

  // Give the keyboard to the rows.
  function focusRows() { list.forceActiveFocus() }

  function columnWidth(index) {
    return Math.max(0, width - 24 - toolsWidth) * columns[index].weight
  }

  Rectangle {
    id: header
    visible: !table.compact
    width: parent.width
    height: table.headerHeight
    color: Qt.alpha(Theme.primary, 0.06)
    border.color: Theme.line
    Row {
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      Repeater {
        model: table.columns
        delegate: Label {
          required property var modelData
          required property int index
          width: table.columnWidth(index)
          height: header.height
          verticalAlignment: Text.AlignVCenter
          text: modelData.title.toUpperCase()
          color: Theme.dim
          font.pixelSize: 9
          font.letterSpacing: 1
          elide: Text.ElideRight
        }
      }
    }
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom; topMargin: table.compact ? 0 : 10 }
    clip: true
    // A row's outline never lies on the clip's edge, where a fractional scale
    // would cut it.
    topMargin: 1
    bottomMargin: 1
    spacing: 2
    model: table.rows
    keyNavigationEnabled: true
    activeFocusOnTab: true
    onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = 0
    Keys.onReturnPressed: if (currentItem) currentItem.open()
    Keys.onDeletePressed: if (currentItem) table.removeRequested(currentItem.modelData)
    Keys.onEscapePressed: table.backRequested()

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property var texts: table.cells(modelData)
      readonly property bool current: ListView.isCurrentItem
      readonly property bool marked: table.selectedId !== "" && table.selectedId === table.idOf(modelData) || (current && (list.activeFocus || toolScope.activeFocus))
      readonly property bool tooled: table.tools !== null && (!table.narrow || hover.hovered || marked)
      readonly property real reserved: tooled ? table.toolsWidth : 0

      function open() {
        list.currentIndex = index
        table.opened(modelData)
      }

      function color(column) {
        return table.tone(modelData, column) || (column === 0 ? Theme.foreground : Theme.dim)
      }

      function reveal() {
        const cells = table.compact ? lines : wide
        for (let i = 0; i < cells.count; i++) {
          const cell = cells.itemAt(i)
          if (cell)
            cell.replay()
        }
      }

      width: list.width
      height: table.rowHeight
      opacity: table.dimmed(modelData) ? 0.4 : 1
      color: marked ? Theme.highlight : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.035) : "transparent"
      border.color: marked ? Theme.primary : Theme.line
      Behavior on color { ColorAnimation { duration: 120 } }
      Behavior on opacity { NumberAnimation { duration: 140 } }

      HoverHandler { id: hover }

      Row {
        visible: !table.compact
        anchors { fill: parent; leftMargin: 12; rightMargin: 12 + row.reserved }
        Repeater {
          id: wide
          model: row.texts
          delegate: DecodeLabel {
            required property string modelData
            required property int index
            width: table.columnWidth(index)
            height: row.height
            verticalAlignment: Text.AlignVCenter
            value: modelData
            soft: true
            revealOnStage: !table.compact
            color: row.color(index)
            font.pixelSize: index === 0 ? 11 : 10
            elide: Text.ElideRight
          }
        }
      }

      Column {
        id: stack
        visible: table.compact
        anchors { left: parent.left; right: statusLabel.left; top: parent.top; leftMargin: 12; rightMargin: 10; topMargin: 11 }
        spacing: 5
        Repeater {
          id: lines
          model: table.stacked
          delegate: DecodeLabel {
            required property var modelData
            required property int index
            width: stack.width
            value: modelData.map(column => row.texts[column]).filter(text => text).join("  ·  ")
            soft: true
            revealOnStage: table.compact
            color: row.color(modelData[0])
            font.pixelSize: index === 0 ? 12 : 10
            elide: Text.ElideRight
          }
        }
      }

      Label {
        id: statusLabel
        visible: table.compact && table.status >= 0
        anchors { right: parent.right; rightMargin: 12 + row.reserved; top: parent.top; topMargin: 12 }
        width: visible ? implicitWidth : 0
        text: table.status >= 0 ? row.texts[table.status] : ""
        color: table.tone(row.modelData, table.status) || Theme.primary
        font.pixelSize: 9
        font.letterSpacing: 1
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.open()
      }

      // Only the selected row's tools are Tab stops; the pointer reaches any.
      FocusScope {
        id: toolScope
        visible: row.tooled
        enabled: row.current || hover.hovered
        anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
        width: tools.width
        height: tools.height
        Loader {
          id: tools
          sourceComponent: table.tools
          onLoaded: item.entry = Qt.binding(() => row.modelData)
        }
        Keys.onEscapePressed: list.forceActiveFocus()
      }
    }
  }

  // Beside the list, not in it: a ListView's children scroll with its empty content.
  Label {
    anchors { left: list.left; right: list.right; top: list.top; margins: 20 }
    visible: list.count === 0
    horizontalAlignment: Text.AlignHCenter
    text: table.emptyText
    color: Theme.dim
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }
}
