pragma ComponentBehavior: Bound
import QtQuick
import "kit/ui"

// Breadcrumb is the way down to what a page shows: its segments in order,
// "Conversation › Bakery website › Home page", each but the last a button
// that goes back up to it. When they do not fit, the first ones give way to
// "…" and the last one elides. The font is monospace, so the room is counted
// in characters.
Item {
  id: crumb

  // The segments, outermost first: [{text}].
  property var trail: []
  property real size: 11
  signal chosen(int index)

  readonly property real advance: Math.max(1, metrics.advanceWidth("0"))
  readonly property int budget: Math.floor(width / advance)
  readonly property string separator: " › "
  // The first segment shown; those before it are "…".
  readonly property int from: {
    const count = trail.length
    let used = count > 0 ? trail[count - 1].text.length : 0
    let first = count - 1
    while (first > 0) {
      const next = trail[first - 1].text.length + separator.length
      const hidden = first - 1 > 0 ? 1 + separator.length : 0
      if (used + next + hidden > budget)
        break
      used += next
      first--
    }
    return Math.max(0, first)
  }

  implicitHeight: metrics.height + 8
  visible: trail.length > 0

  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: crumb.size }

  Row {
    id: line
    anchors.verticalCenter: parent.verticalCenter
    width: crumb.width
    spacing: 0

    Label {
      visible: crumb.from > 0
      text: "…" + crumb.separator
      color: Theme.dim
      font.pixelSize: crumb.size
    }
    Repeater {
      model: crumb.trail.length
      delegate: Row {
        id: segment
        required property int index
        readonly property bool last: index === crumb.trail.length - 1
        visible: index >= crumb.from
        Label {
          id: name
          width: segment.last ? Math.min(implicitWidth, Math.max(0, crumb.width - segment.x)) : implicitWidth
          text: crumb.trail[segment.index] ? crumb.trail[segment.index].text : ""
          color: segment.last ? Theme.foreground : hover.hovered || segment.activeFocus ? Theme.primary : Theme.dim
          font.pixelSize: crumb.size
          font.underline: !segment.last && hover.hovered
          elide: Text.ElideRight
          HoverHandler { id: hover; enabled: !segment.last; cursorShape: Qt.PointingHandCursor }
          TapHandler { enabled: !segment.last; onTapped: crumb.chosen(segment.index) }
        }
        Label {
          visible: !segment.last
          text: crumb.separator
          color: Theme.dim
          font.pixelSize: crumb.size
        }
        activeFocusOnTab: !last
        Accessible.role: Accessible.Button
        Accessible.name: name.text
        Keys.onReturnPressed: crumb.chosen(index)
        Keys.onSpacePressed: crumb.chosen(index)
      }
    }
  }
}
