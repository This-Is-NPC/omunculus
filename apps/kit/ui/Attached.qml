pragma ComponentBehavior: Bound
import QtQuick

// Attached hangs a card (a request, a note) on the work that made it: the
// lifeline of its depth passes beside it and a dashed connector runs from the
// left edge, labelled with the level it goes to ("L0" for the person), into
// the card's top. Put the card inside it; it takes the room right of the
// lifeline. Geometry as Lifeline: `depth` is the card's column (its work's
// depth + 1), rails, `through` whether the work's line goes on past it;
// `origin` is where column 0 starts, the width the connector crosses.
// `tone` colours the connector.
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
  readonly property real connectorY: Theme.space.tight + Theme.space.inset

  implicitHeight: slot.childrenRect.height + Theme.space.tight * 2

  Lifeline {
    depth: attached.depth
    rails: attached.rails
    line: attached.through ? "through" : "none"
    unit: attached.unit
    origin: attached.origin
  }

  // The dashes, from the edge to the card.
  Row {
    x: 0
    y: attached.connectorY
    spacing: Theme.space.line
    Repeater {
      model: Math.max(0, Math.floor((attached.textX - attached.origin / 2) / (Theme.space.line * 2)))
      Rectangle { width: Theme.space.line; height: 1; color: attached.tone }
    }
  }
  Label {
    visible: attached.level !== "" && attached.origin > 0
    x: 0
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
