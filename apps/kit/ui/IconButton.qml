import QtQuick
import "Breakpoints.js" as Breakpoints

// IconButton is a square button that is only an icon, its name in the tip;
// taller on a narrow window, where it is touched rather than pointed at.
// With a `reason` it is off: it reads disabled and does nothing, but says why
// on hover. `quiet`, it has no frame and a fainter glyph until hovered or
// highlighted, for a button repeated on every row of a list.
Rectangle {
  id: button

  property string name
  property real size: 12
  property string tip
  property color tone: Theme.primary
  property bool highlighted: false
  // Why it cannot be pressed now; empty while it can.
  property string reason
  property bool quiet: false
  // A count waiting behind the button, on a badge at its corner; none hides it.
  property int count: 0
  readonly property bool off: !enabled || reason !== ""
  readonly property bool hovered: pointer.containsMouse && reason === ""

  signal clicked()

  implicitWidth: Breakpoints.target(Window.width)
  implicitHeight: implicitWidth
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: tip
  Accessible.onPressAction: press()
  color: hovered || highlighted ? Qt.alpha(tone, 0.1) : "transparent"
  border.color: hovered || highlighted ? tone : quiet ? "transparent" : Theme.line
  opacity: off ? 0.35 : 1
  scale: pointer.pressed && !off ? 0.9 : 1

  Behavior on color { ColorAnimation { duration: 150 } }
  Behavior on border.color { ColorAnimation { duration: 150 } }
  Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

  function press() { if (!off) { hint.dismiss(); tap.restart(); clicked() } }
  Keys.onEscapePressed: event => { event.accepted = hint.visible; hint.dismiss() }
  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()

  Icon {
    id: glyph
    anchors.centerIn: parent
    name: button.name
    size: button.size
    color: button.hovered || button.highlighted ? button.tone : button.quiet ? Qt.alpha(Theme.dim, 0.6) : Theme.dim
    Behavior on color { ColorAnimation { duration: 150 } }
  }

  Rectangle {
    anchors { left: parent.left; bottom: parent.bottom }
    width: button.hovered || button.highlighted ? parent.width : 0
    height: 2
    color: button.tone
    Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
  }

  Rectangle {
    visible: button.count > 0
    anchors { right: parent.right; top: parent.top; margins: -5 }
    width: Math.max(height, tally.implicitWidth + 6)
    height: 13
    color: button.tone
    Label {
      id: tally
      anchors.centerIn: parent
      text: button.count
      color: Theme.badgeForeground
      font.pixelSize: 9
      font.bold: true
    }
  }

  SequentialAnimation {
    id: tap
    NumberAnimation { target: glyph; property: "scale"; from: 1; to: 1.22; duration: 90 }
    NumberAnimation { target: glyph; property: "scale"; to: 1; duration: 150; easing.type: Easing.OutCubic }
  }

  MouseArea {
    id: pointer
    anchors { fill: parent; margins: -4 }
    hoverEnabled: true
    cursorShape: button.off ? Qt.ArrowCursor : Qt.PointingHandCursor
    onPressed: hint.dismiss()
    onClicked: button.press()
  }
  FocusRing {}
  Hint { id: hint; active: pointer.containsMouse || button.activeFocus; text: button.reason || button.tip }
}
