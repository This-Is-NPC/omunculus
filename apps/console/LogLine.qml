pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// LogLine is one system row of a thread, the log and not a message: an icon
// in the row's mark column, the agents it names, each in its tone and joined
// by "›", what happened in dim words, and the time at its right; a second
// line, under the words, says more. Live, the mark is a dot that breathes
// in the tone of the agent at work, and a trace runs at the row's end.
Item {
  id: row

  // The mark: an Icon name, drawn in `tone`.
  property string icon: "check"
  property color tone: Theme.dim
  // The agents named, from the top.
  property var names: []
  property string text: ""
  // Words that say something went wrong.
  property bool failed: false
  property string detail: ""
  property string stamp: ""
  property bool live: false

  // The names that fit in about half the row, the first ones giving way to "…".
  readonly property var shown: {
    const room = Math.floor((width - Theme.size.mark) * 0.6 / Math.max(1, metrics.averageCharacterWidth))
    let kept = names.slice()
    while (kept.length > 1 && kept.join(" › ").length > room)
      kept = kept[0] === "…" ? ["…"].concat(kept.slice(2)) : ["…"].concat(kept.slice(1))
    return kept
  }
  FontMetrics { id: metrics; font.family: Theme.fontFamily; font.pixelSize: Theme.type.log.size }

  implicitHeight: lines.implicitHeight + Theme.space.row
  Accessible.role: Accessible.StaticText
  Accessible.name: names.join(", ") + " " + text + (detail !== "" ? ": " + detail : "")

  ColumnLayout {
    id: lines
    width: row.width
    spacing: Theme.space.row

    RowLayout {
      Layout.fillWidth: true
      implicitHeight: Theme.size.stackedLine
      spacing: 0

      Item {
        Layout.preferredWidth: Theme.size.mark
        Layout.preferredHeight: Theme.type.log.size
        Layout.alignment: Qt.AlignVCenter
        Icon { visible: !row.live; anchors.verticalCenter: parent.verticalCenter; name: row.icon; size: Theme.type.log.size; color: row.tone }
        Dot {
          id: pulse
          visible: row.live
          anchors.verticalCenter: parent.verticalCenter
          tone: row.tone
          SequentialAnimation on opacity {
            running: row.live && !Theme.reducedMotion
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
          }
        }
      }
      // The names in their tones, whole; the words after them give way.
      Repeater {
        model: row.shown
        delegate: Label {
          required property string modelData
          required property int index
          text: (index > 0 ? " › " : "") + modelData
          color: modelData === "…" ? Theme.dim : Omunculus.toneOf(modelData)
          font.pixelSize: Theme.type.log.size
        }
      }
      Label {
        Layout.minimumWidth: 0
        Layout.fillWidth: true
        text: (row.names.length > 0 ? "  " : "") + row.text
        color: row.failed ? Theme.error : Theme.dim
        font.pixelSize: Theme.type.log.size
        elide: Text.ElideRight
      }
      // Under a bubble's measure the breathing dot says it alone.
      LoadingTrace {
        visible: row.live && row.width >= Theme.size.measureFrom
        Layout.preferredWidth: 2 * Theme.size.gutter
        Layout.preferredHeight: Theme.type.log.size
        Layout.leftMargin: Theme.space.gap
        Layout.alignment: Qt.AlignVCenter
        running: visible && !Theme.reducedMotion
        tone: row.tone
      }
      Label {
        visible: row.stamp !== ""
        Layout.leftMargin: Theme.space.gap
        text: row.stamp
        color: Theme.faint
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }
    }

    Label {
      visible: row.detail !== ""
      Layout.fillWidth: true
      Layout.leftMargin: Theme.size.mark
      text: row.detail
      color: row.failed ? Theme.error : Theme.foreground
      font.pixelSize: Theme.type.log.size
      wrapMode: Text.Wrap
      maximumLineCount: 4
      elide: Text.ElideRight
    }
  }
}
