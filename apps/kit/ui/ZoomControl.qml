import QtQuick

// ZoomControl is how near a canvas is, and the ways to bring it nearer,
// farther, to its actual size (pressing the number) or all in view; the
// keyboard reaches each, and Enter or Space presses it.
Rectangle {
  id: control

  // What it zooms: anything with zoomLevel, zoomIn, zoomOut, actualSize and fit.
  required property var target

  // An icon pressed on its own, without a frame.
  component Glyph: Item {
    id: glyph
    property string name
    signal clicked()
    width: 36
    height: 36
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    Icon {
      anchors.centerIn: parent
      name: glyph.name
      size: 12
      color: pointer.containsMouse || glyph.activeFocus ? Theme.primary : Theme.dim
      Behavior on color { ColorAnimation { duration: 150 } }
    }
    MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: glyph.clicked() }
    FocusRing {}
  }

  width: row.implicitWidth
  height: 36
  color: Qt.alpha(Theme.background, 0.94)
  border.color: Theme.line

  Row {
    id: row
    height: parent.height
    Glyph { name: "chevron-down"; onClicked: control.target.zoomOut() }
    Item {
      id: actual
      width: 76
      height: parent.height
      activeFocusOnTab: true
      Keys.onReturnPressed: control.target.actualSize()
      Keys.onSpacePressed: control.target.actualSize()
      DecodeLabel {
        anchors.centerIn: parent
        value: Math.round(control.target.zoomLevel * 100) + " %"
        autoPlay: false
        color: zoomPointer.containsMouse || actual.activeFocus ? Theme.primary : Theme.foreground
        font.pixelSize: 12
        font.letterSpacing: 2
      }
      MouseArea { id: zoomPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: control.target.actualSize() }
      FocusRing {}
    }
    Glyph { name: "chevron-up"; onClicked: control.target.zoomIn() }
    Glyph { name: "map"; onClicked: control.target.fit() }
  }
}
