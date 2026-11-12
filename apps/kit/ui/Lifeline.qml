import QtQuick

// Lifeline draws the depth lines of one row of the hierarchy, the one grammar
// of every view that shows agents by level (chat, tree, log, cost, artifacts).
// Place it filling the row, under its content. Each level is a column of
// `unit` px, from `origin`; the row's mark is in the column `depth`.
//   rails  one bool per column left of the parent's: whether that ancestor's
//          line goes on down through this row (Tree.js `rows` and `stream`).
//   line   "elbow": the parent's line comes down to this row's mark and turns
//          into it (to the mark only when `last`, else on down); "through":
//          the parent's line passes by a row that hangs under it; "none".
//   stem   the row's own line leaves its mark down, to the rows under it.
// `markY` is where the mark's centre is, from the row's top.
Item {
  id: lines

  property int depth: 0
  property var rails: []
  property string line: "none"
  property bool last: false
  property bool stem: false
  property real unit: Theme.size.gutter
  property real origin: 0
  property real markY: Theme.space.tight + Theme.size.stackedLine / 2
  property color tone: Theme.faint

  readonly property real elbowX: origin + (depth - 1) * unit + unit / 2
  readonly property real markX: origin + depth * unit + unit / 2

  anchors.fill: parent

  Repeater {
    model: lines.rails
    delegate: Rectangle {
      required property bool modelData
      required property int index
      visible: modelData
      x: lines.origin + index * lines.unit + lines.unit / 2
      width: 1
      height: lines.height
      color: lines.tone
    }
  }
  Rectangle {
    visible: lines.depth > 0 && lines.line !== "none"
    x: lines.elbowX
    width: 1
    height: lines.line === "elbow" && lines.last ? lines.markY : lines.height
    color: lines.tone
  }
  Rectangle {
    visible: lines.depth > 0 && lines.line === "elbow"
    x: lines.elbowX
    y: lines.markY
    width: lines.markX - lines.elbowX - Theme.space.tight
    height: 1
    color: lines.tone
  }
  Rectangle {
    visible: lines.stem
    x: lines.markX
    y: lines.markY + Theme.space.tight
    width: 1
    height: lines.height - y
    color: lines.tone
  }
}
