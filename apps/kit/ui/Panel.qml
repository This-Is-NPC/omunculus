import QtQuick

// Panel is a framed section with an index, title, and content.
SurfaceFrame {
  id: panel

  property string title
  property string index
  default property alias content: body.data

  // Natural height: heading, margins and the first child's own height, so a
  // panel can sit in a stacked layout without being told how tall to be.
  implicitHeight: heading.height + 38 + (body.children.length > 0 ? body.children[0].implicitHeight : 0)

  function replayTitle() { headingTitle.replay() }

  Row {
    id: heading
    anchors { left: parent.left; top: parent.top; leftMargin: 14; topMargin: 12 }
    spacing: 10
    Label {
      visible: panel.index.length > 0
      text: panel.index
      color: panel.tone
      font.pixelSize: 10
      font.letterSpacing: 2
    }
    DecodeLabel {
      id: headingTitle
      value: panel.title.toUpperCase()
      soft: true
      color: panel.active ? panel.tone : Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 3
    }
  }

  Item {
    id: body
    anchors { left: parent.left; right: parent.right; top: heading.bottom; bottom: parent.bottom; margins: 14; topMargin: 12 }
    clip: true
  }
}
