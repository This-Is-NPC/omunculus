import QtQuick
import "Breakpoints.js" as Breakpoints

// Chip is a quiet button: a hairline box whose text lights on hover, with an
// accent underline that grows from the left; it gives a little when pressed
// and takes the accent, with a faint wash, when on. On `alert`, as a filter
// over something waiting on the person, its text keeps the accent off too
// and never dims. With a `reason` it is off:
// it reads disabled and does nothing, but says why on hover. It is never
// wider than `maximumWidth`, its text eliding instead.
Rectangle {
  id: chip

  property string text
  // Optional icon before the text, from Icon's set.
  property string icon
  // Optional colour before the text, as a small square, as an agent's.
  property color swatch: "transparent"
  // Room kept on the right for something drawn over the chip, like a chevron.
  property real trailing: 0
  // A chip that leads to another view slides right as the view leaves left.
  property bool departs: false
  property bool checked: false
  property bool dim: false
  property bool alert: false
  property color accent: Theme.primary
  property string tip
  // Why it cannot be pressed now; empty while it can.
  property string reason
  property real maximumWidth: Breakpoints.room(parent)
  readonly property bool off: !enabled || reason !== ""
  readonly property bool hovered: mouse.containsMouse && reason === ""

  signal clicked()

  // The room the swatch and the icon take before the text.
  readonly property real iconRoom: (icon ? 12 + content.spacing : 0) + (swatch.a > 0 ? 6 + content.spacing : 0)
  implicitWidth: iconRoom + label.implicitWidth + 20 + trailing
  implicitHeight: Theme.size.chip
  // The width, not the implicit width, is bounded: what sizes itself from the
  // chip's implicit width never depends on its own.
  width: Math.min(implicitWidth, maximumWidth)
  activeFocusOnTab: !off
  color: checked ? Qt.alpha(accent, 0.12) : (hovered ? Qt.alpha(accent, 0.05) : "transparent")
  border.color: checked ? accent : (hovered ? Theme.dim : Theme.line)
  opacity: off ? 0.35 : (dim && !alert && !hovered ? 0.6 : 1)
  scale: mouse.pressed && !off ? 0.96 : 1
  transform: Translate { id: nudge }

  Behavior on color { ColorAnimation { duration: 140 } }
  Behavior on border.color { ColorAnimation { duration: 140 } }
  Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
  Behavior on opacity { NumberAnimation { duration: 140 } }

  Keys.onReturnPressed: press()
  Keys.onSpacePressed: press()

  // The ink at rest; a chip on a tinted fill lifts it to stay readable.
  property color restInk: Theme.dim
  property color ink: chip.checked || chip.alert ? chip.accent : (chip.hovered ? Theme.foreground : chip.restInk)
  Behavior on ink { ColorAnimation { duration: 140 } }

  Row {
    id: content
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: -chip.trailing / 2
    spacing: (chip.icon || chip.swatch.a > 0) && chip.text ? 8 : 0
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: chip.swatch.a > 0
      width: 6
      height: 6
      color: chip.swatch
    }
    Icon {
      anchors.verticalCenter: parent.verticalCenter
      visible: chip.icon.length > 0
      name: chip.icon
      size: 12
      color: chip.ink
    }
    Label {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, Math.min(implicitWidth, chip.width - 20 - chip.trailing - chip.iconRoom))
      elide: Text.ElideRight
      text: chip.text
      color: chip.ink
      font.pixelSize: 11
      font.letterSpacing: 1.5
    }
  }

  Rectangle {
    anchors { left: parent.left; bottom: parent.bottom }
    height: 1
    width: chip.hovered || chip.checked ? parent.width : 0
    color: chip.accent
    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
  }

  MouseArea {
    id: mouse
    anchors { fill: parent; margins: -4 }
    hoverEnabled: true
    cursorShape: chip.off ? Qt.ArrowCursor : Qt.PointingHandCursor
    onClicked: chip.press()
  }

  // Run the chip as if clicked, from the pointer or a key.
  function press() {
    if (chip.off)
      return
    if (chip.departs && !Theme.reducedMotion)
      depart.restart()
    chip.clicked()
  }

  SequentialAnimation {
    id: depart
    NumberAnimation { target: nudge; property: "x"; from: 0; to: 22; duration: 200; easing.type: Easing.OutCubic }
    PauseAnimation { duration: 200 }
    NumberAnimation { target: nudge; property: "x"; to: 0; duration: 0 }
  }

  FocusRing {}

  Hint {
    active: mouse.containsMouse && text.length > 0
    text: chip.reason || chip.tip
  }
}
