import QtQuick
import "kit/ui"

// SpeechTurn is one thing said in the conversation, in a box under a heading
// of its speaker's tone dot, name and time, with the files attached with it
// below: yours on the right, its lines left aligned in the box; each agent's
// on the left tinted with its colour; a note the harness left, no one's
// words, on the left too, muted, under NOTE where a name would be. A line
// that continues the same speaker's turn drops the heading and sits close to
// the one before.
Item {
  id: turn

  required property string who
  required property string text
  required property bool mine
  property bool note: false
  // Yours, still on its way: dim, SENDING… where the time goes.
  property bool pending: false
  required property string stamp
  // The files attached with it, as JSON.
  required property string files
  property bool continued: false

  readonly property var attached: JSON.parse(files)
  readonly property color tone: turn.note ? Theme.dim : Omunculus.toneOf(who)
  // At most this wide: the whole width on a narrow window, about three
  // quarters otherwise, and about 70 characters at most per line.
  readonly property real widest: Math.min(620, turn.width < Theme.size.measureFrom ? turn.width : turn.width * Theme.size.measure)
  readonly property real inset: Theme.size.bubbleInset

  implicitHeight: (chips.visible ? chips.y + chips.height : body.y + body.height) + Theme.space.row

  Column {
    id: body
    y: turn.continued ? Theme.space.row : Theme.space.inset
    width: Math.min(turn.widest, Math.max(heading.implicitWidth, line.implicitWidth + 2 * turn.inset))
    x: turn.mine ? turn.width - width : 0
    spacing: Theme.space.line
    opacity: turn.pending ? 0.55 : 1

    Row {
      id: heading
      visible: !turn.continued
      spacing: Theme.space.tight
      x: turn.mine ? body.width - width : 0
      Dot { anchors.verticalCenter: parent.verticalCenter; tone: turn.tone }
      Label { text: turn.note ? "NOTE" : turn.who.toUpperCase(); color: turn.tone; font.pixelSize: Theme.type.name.size; font.letterSpacing: Theme.type.name.tracking }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        text: turn.pending ? "SENDING…" : turn.stamp
        color: Qt.alpha(turn.tone, Theme.type.stamp.opacity)
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }
    }

    Rectangle {
      width: parent.width
      height: line.implicitHeight + Theme.space.inset
      color: turn.mine ? Theme.highlight : Qt.tint(Theme.background, Qt.alpha(turn.tone, 0.1))
      Prose {
        id: line
        anchors.verticalCenter: parent.verticalCenter
        x: turn.inset
        width: parent.width - 2 * turn.inset
        // Yours sits on the right, its lines read from the left.
        horizontalAlignment: Text.AlignLeft
        plain: turn.mine
        source: turn.mine ? turn.text : Omunculus.inline(turn.text)
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
      }
    }
  }

  // The files attached with it, on its side, each opening when chosen.
  Flow {
    id: chips
    visible: turn.attached.length > 0
    x: turn.mine ? turn.width - width : 0
    y: body.y + body.height + Theme.space.tight
    width: turn.widest
    layoutDirection: turn.mine ? Qt.RightToLeft : Qt.LeftToRight
    spacing: Theme.space.tight
    Repeater {
      model: turn.attached
      delegate: FileChip {
        required property var modelData
        file: modelData
        onClicked: Omunculus.openAttachment(modelData)
      }
    }
  }
}
