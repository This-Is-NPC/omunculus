pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Breakpoints.js" as Breakpoints

// Masthead is the window's top line: the name, the crumbs of where the window
// is, the readout on the right, and a hairline that fades out from an accent
// notch. A crumb with `run` is a link that runs it. When the crumbs do not
// fit they elide from the left: the first, the project, down to 8
// characters and no further, then the middle ones, then the last. On a
// narrow window the name is smaller and less tracked, leaving the crumbs
// their room.
ColumnLayout {
  id: mast
  // Where the window is, outermost first: [{text, run}], `run` optional.
  property var crumbs: []
  readonly property var trail: crumbs
  readonly property bool narrow: Breakpoints.size(Window.width) === "narrow"
  default property alias trailing: tail.data
  spacing: 10

  readonly property string heading: trail.map(crumb => crumb.text).join(" / ")
  onHeadingChanged: if (!Theme.reducedMotion) sweep.restart()

  // The font is monospace, so the room is counted in characters.
  readonly property real advance: Math.max(1, metrics.advanceWidth("0") + 2)
  readonly property real gap: 8
  readonly property real separatorWidth: advance + 2 * gap
  // The fewest characters each crumb keeps.
  function floorOf(index, length) {
    const count = trail.length
    return index === count - 1 ? 0 : index === 0 ? Math.min(length, 8) : Math.min(length, 1)
  }
  // Each crumb's width in `room`, shortened from the left down to its floor;
  // one left whole is not bounded, so rounding never elides it.
  function widths(room) {
    const lengths = trail.map(crumb => String(crumb.text).length)
    const counts = lengths.slice()
    let over = lengths.reduce((sum, length) => sum + length, 0) - Math.floor((room - separatorWidth * Math.max(0, trail.length - 1)) / advance)
    for (let index = 0; index < counts.length && over > 0; index++) {
      const cut = Math.min(over, counts[index] - floorOf(index, lengths[index]))
      counts[index] -= cut
      over -= cut
    }
    return counts.map((count, index) => count === lengths[index] ? Infinity : count * advance)
  }
  readonly property real fullWidth: trail.reduce((sum, crumb) => sum + String(crumb.text).length * advance, 0) + separatorWidth * Math.max(0, trail.length - 1)
  readonly property real floorWidth: trail.reduce((sum, crumb, index) => sum + floorOf(index, String(crumb.text).length) * advance, 0) + separatorWidth * Math.max(0, trail.length - 1)

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: 11 }

  RowLayout {
    Layout.fillWidth: true
    spacing: 10
    Label { text: "OMUNCULUS"; font.pixelSize: mast.narrow ? 12 : 15; font.bold: true; font.letterSpacing: mast.narrow ? 3 : 6 }
    Label { text: "╱"; color: Theme.primary; font.pixelSize: 13 }
    Item {
      id: area
      Layout.fillWidth: true
      // The crumbs keep their floors before the readout on the right; a
      // wider minimum would widen the whole view.
      Layout.minimumWidth: Math.min(mast.fullWidth, mast.floorWidth)
      implicitWidth: mast.fullWidth
      implicitHeight: metrics.height
      readonly property var widths: mast.widths(width)

      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: mast.gap
        Repeater {
          model: mast.trail.length
          delegate: Row {
            id: crumb
            required property int index
            readonly property var item: mast.trail[index] || ({ text: "" })
            readonly property bool link: typeof item.run === "function"
            readonly property real room: area.widths[index] || 0
            readonly property int elision: index === 0 || index === mast.trail.length - 1 ? Text.ElideRight : Text.ElideLeft
            spacing: mast.gap
            Label {
              visible: crumb.index > 0
              text: "/"
              color: Theme.dim
              font.pixelSize: 11
            }
            Label {
              visible: !crumb.link
              width: Math.min(implicitWidth, crumb.room)
              text: String(crumb.item.text).toUpperCase()
              color: Theme.dim
              font.pixelSize: 11
              font.letterSpacing: 2
              elide: crumb.elision
            }
            LinkLabel {
              visible: crumb.link
              width: Math.min(implicitWidth, crumb.room)
              value: String(crumb.item.text).toUpperCase()
              font.letterSpacing: 2
              elide: crumb.elision
              onClicked: crumb.item.run()
            }
          }
        }
      }
    }
    RowLayout { id: tail; spacing: 14 }
  }

  Item {
    Layout.fillWidth: true
    implicitHeight: 1
    Rectangle {
      id: notch
      width: 28
      height: 1
      color: Theme.primary
      // The notch sweeps along the rule whenever the crumbs change.
      SequentialAnimation {
        id: sweep
        NumberAnimation { target: notch; property: "x"; from: 0; to: mast.width - 28; duration: 420; easing.type: Easing.InOutCubic }
        NumberAnimation { target: notch; property: "x"; to: 0; duration: 0 }
      }
    }
    Rectangle {
      x: 32
      width: parent.width - 32
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: Theme.line }
        GradientStop { position: 1; color: "transparent" }
      }
    }
  }
}
