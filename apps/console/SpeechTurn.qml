import QtQuick
import "kit/ui"

// SpeechTurn is one thing said in the conversation, in a box, with the files
// attached with it below: yours on the right, its lines left aligned in the
// box; each agent's on the left tinted with its colour, under its portrait; a
// note the harness left, no one's words, on the left too, muted, under NOTE
// where a name would be. A line that continues the same speaker's turn drops
// the name and time and sits close to the one before.
Item {
  id: turn

  required property string who
  required property string text
  required property bool mine
  property bool note: false
  required property string stamp
  // The files attached with it, as JSON.
  required property string files
  property bool continued: false

  readonly property var attached: JSON.parse(files)
  readonly property color tone: Omunculus.toneOf(who)
  // At most this wide: the whole width on a narrow window, about three quarters otherwise.
  // About 70 characters at most per line.
  readonly property real widest: Math.min(620, turn.width < 520 ? turn.width : turn.width * 0.78)
  readonly property real inset: 10

  implicitHeight: (chips.visible ? chips.y + chips.height : body.y + body.height) + 2

  Column {
    id: body
    y: turn.continued ? 2 : 14
    width: Math.min(turn.widest, Math.max(heading.implicitWidth, line.implicitWidth + 2 * turn.inset))
    x: turn.mine ? turn.width - width : 0
    spacing: 4

    Row {
      id: heading
      visible: !turn.continued
      spacing: 8
      x: turn.mine ? body.width - width : 0
      Rectangle { visible: turn.mine; width: 5; height: 5; anchors.verticalCenter: parent.verticalCenter; color: turn.tone }
      Portrait { visible: !turn.mine && !turn.note && turn.who !== ""; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter; agent: turn.who; source: Omunculus.imageOf(turn.who); tone: Omunculus.toneOf(turn.who) }
      Label { text: turn.note ? "NOTE" : turn.who.toUpperCase(); color: turn.tone; font.pixelSize: 11; font.letterSpacing: 2 }
      Label { text: turn.stamp; color: Theme.dim; font.pixelSize: 11 }
    }

    Rectangle {
      width: parent.width
      height: line.implicitHeight + 14
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
        font.pixelSize: 12
        lineHeight: 1.2
        wrapMode: Text.Wrap
      }
    }
  }

  // The files attached with it, on its side, each opening when chosen.
  Flow {
    id: chips
    visible: turn.attached.length > 0
    x: turn.mine ? turn.width - width : 0
    y: body.y + body.height + 6
    width: turn.widest
    layoutDirection: turn.mine ? Qt.RightToLeft : Qt.LeftToRight
    spacing: 6
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
