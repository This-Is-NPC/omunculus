pragma ComponentBehavior: Bound
import QtQuick

// Attached hangs a card (a request, a note) on the work that made it: the
// work's lifeline comes down to the card, and a dashed connector leaves it,
// labelled with the work's level ("L2"), into the card's side. Put the card
// inside it; it takes the room right of the lifeline. Geometry as Lifeline:
// `depth` is the card's column (its work's depth + 1), rails, `through`
// whether the work's line goes on past the card, else it ends at the
// connector; `origin` is where column 0 starts. `tone` colours the connector.
Item {
  id: attached

  property int depth: 1
  property var rails: []
  property bool through: false
  property real unit: Theme.size.gutter
  property real origin: 0
  property string level: ""
  property color tone: Theme.warning
  default property alias content: slot.data

  readonly property real textX: origin + (depth + 1) * unit
  // The work's own line: the column before the card's.
  readonly property real lineX: origin + (depth - 1) * unit + unit / 2
  readonly property real connectorY: Theme.space.tight + Theme.space.inset

  implicitHeight: slot.childrenRect.height + Theme.space.tight * 2

  Lifeline {
    depth: attached.depth
    rails: attached.rails
    line: attached.through ? "through" : "none"
    unit: attached.unit
    origin: attached.origin
  }

  // The work's line, down to the connector when it goes no further.
  Rectangle {
    visible: !attached.through
    x: attached.lineX
    width: 1
    height: attached.connectorY
    color: Theme.faint
  }

  // The dashes, from the work's line to the card.
  Row {
    x: attached.lineX
    y: attached.connectorY
    spacing: Theme.space.line
    Repeater {
      model: Math.max(0, Math.floor((attached.textX - attached.lineX) / (Theme.space.line * 2)))
      Rectangle { width: Theme.space.line; height: 1; color: attached.tone }
    }
  }
  Label {
    visible: attached.level !== ""
    x: attached.lineX + Theme.space.tight
    y: attached.connectorY - height - Theme.space.row
    text: attached.level
    color: attached.tone
    font.pixelSize: Theme.type.stamp.size
  }

  Item {
    id: slot
    x: attached.textX
    y: Theme.space.tight
    width: attached.width - x - Theme.space.cell
    height: childrenRect.height
  }
}
