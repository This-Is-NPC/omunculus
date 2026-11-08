pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Breakpoints.js" as Breakpoints

// Masthead is the window's top line: the name, the crumbs of where the window
// is, the readout on the right, and a hairline that fades out from an accent
// notch. Crumbs without text are left out, and the name's slash shows only
// before a crumb. A crumb with `run` is a link that runs it. When the crumbs
// do not fit they elide from the left: the first, the project, down to 8
// characters and no further, then the middle ones, then the last. Under
// 560 px the name is left out, leaving the crumbs its room. Tight, it packs
// closer to give its height and width to what is below and on the right.
ColumnLayout {
  id: mast
  // Where the window is, outermost first: [{text, run}], `run` optional.
  property var crumbs: []
  property bool tight: false
  // Whether the name leads the line; without it, the crumbs do.
  property bool branded: Window.width >= 560
  readonly property var shown: crumbs.filter(crumb => String(crumb.text) !== "")
  default property alias trailing: tail.data
  spacing: tight ? Theme.space.tight : Theme.space.gap

  readonly property string heading: shown.map(crumb => crumb.text).join(" / ")
  onHeadingChanged: if (!Theme.reducedMotion) sweep.restart()

  // The font is monospace, so the room is counted in characters.
  readonly property real advance: Math.max(1, metrics.advanceWidth("0") + Theme.type.section.tracking)
  readonly property real gap: 8
  readonly property real separatorWidth: advance + 2 * gap
  // The fewest characters each crumb keeps.
  function floorOf(index, length) {
    const count = shown.length
    return index === count - 1 ? 0 : index === 0 ? Math.min(length, 8) : Math.min(length, 1)
  }
  // Each crumb's width in `room`, shortened from the left down to its floor;
  // one left whole is not bounded, so rounding never elides it.
  function widths(room) {
    const lengths = shown.map(crumb => String(crumb.text).length)
    const counts = lengths.slice()
    let over = lengths.reduce((sum, length) => sum + length, 0) - Math.floor((room - separatorWidth * Math.max(0, shown.length - 1)) / advance)
    for (let index = 0; index < counts.length && over > 0; index++) {
      const cut = Math.min(over, counts[index] - floorOf(index, lengths[index]))
      counts[index] -= cut
      over -= cut
    }
    return counts.map((count, index) => count === lengths[index] ? Infinity : count * advance)
  }
  readonly property real fullWidth: shown.reduce((sum, crumb) => sum + String(crumb.text).length * advance, 0) + separatorWidth * Math.max(0, shown.length - 1)
  readonly property real floorWidth: shown.reduce((sum, crumb, index) => sum + floorOf(index, String(crumb.text).length) * advance, 0) + separatorWidth * Math.max(0, shown.length - 1)

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: Theme.type.section.size }

  RowLayout {
    Layout.fillWidth: true
    // As tall with or without an icon button on the right, so the rule
    // does not move between pages.
    Layout.minimumHeight: Breakpoints.target(Window.width)
    spacing: Theme.space.gap
    Label { visible: mast.branded; text: "OMUNCULUS"; font.pixelSize: 15; font.bold: true; font.letterSpacing: 6 }
    Label { visible: mast.branded && mast.shown.length > 0; text: "╱"; color: Theme.primary; font.pixelSize: 13 }
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
          model: mast.shown.length
          delegate: Row {
            id: crumb
            required property int index
            readonly property var item: mast.shown[index] || ({ text: "" })
            readonly property bool link: typeof item.run === "function"
            readonly property real room: area.widths[index] || 0
            readonly property int elision: index === 0 || index === mast.shown.length - 1 ? Text.ElideRight : Text.ElideLeft
            spacing: mast.gap
            Label {
              visible: crumb.index > 0
              text: "/"
              color: Theme.dim
              font.pixelSize: Theme.type.section.size
            }
            Label {
              visible: !crumb.link
              width: Math.min(implicitWidth, crumb.room)
              text: String(crumb.item.text).toUpperCase()
              color: Theme.dim
              font.pixelSize: Theme.type.section.size
              font.letterSpacing: Theme.type.section.tracking
              elide: crumb.elision
            }
            LinkLabel {
              visible: crumb.link
              width: Math.min(implicitWidth, crumb.room)
              value: String(crumb.item.text).toUpperCase()
              font.pixelSize: Theme.type.section.size
              font.letterSpacing: Theme.type.section.tracking
              elide: crumb.elision
              onClicked: crumb.item.run()
            }
          }
        }
      }
    }
    RowLayout { id: tail; spacing: mast.tight ? 8 : Theme.space.block }
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
