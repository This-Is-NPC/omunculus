import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ResolvedLine is what you did to a request, collapsed to one sentence with
// its kind's icon and word (ANSWERED, CHOSE, GRANTED, DENIED) and the time.
// The word, the sentence and the time are on one line; narrow, the word is
// over the sentence, which ends with the time.
Item {
  id: line

  property string icon
  property string word
  property string sentence
  property string stamp

  readonly property bool stacked: width < Theme.size.measureFrom

  implicitHeight: layout.implicitHeight + Theme.space.gap + Theme.space.gap

  RowLayout {
    id: layout
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
    spacing: Theme.space.gap
    Icon { Layout.alignment: Qt.AlignTop; name: line.icon; size: 16; color: Theme.dim }
    GridLayout {
      Layout.fillWidth: true
      columns: line.stacked ? 1 : 3
      columnSpacing: Theme.space.gap
      rowSpacing: Theme.space.line
      Label {
        Layout.preferredWidth: line.stacked ? -1 : 76
        text: line.word
        color: Theme.dim
        font.pixelSize: Theme.type.header.size
        font.letterSpacing: Theme.type.kicker.tracking
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: line.sentence + (line.stacked ? Theme.type.meta.separator + line.stamp : "")
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
      }
      Label {
        visible: !line.stacked
        text: line.stamp
        color: Theme.faint
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }
    }
  }
}
