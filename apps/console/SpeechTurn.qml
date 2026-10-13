import QtQuick
import "kit/ui"

// SpeechTurn is one thing said in the conversation, in a box, with the files
// attached with it below: yours on the right, each agent's on the left tinted
// with its colour, under its portrait. A line that continues the same
// speaker's turn drops the name and time and sits close to the one before.
Item {
  id: turn

  required property string who
  required property string text
  required property bool mine
  required property string stamp
  // The files attached with it, as JSON.
  required property string files
  property bool continued: false

  readonly property var attached: JSON.parse(files)
  readonly property color tone: Omunculus.toneOf(who)
  // At most this wide: the whole width on a narrow window, about three quarters otherwise.
  readonly property real widest: turn.width < 520 ? turn.width : turn.width * 0.78
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
      Portrait { visible: !turn.mine && turn.who !== ""; width: 20; height: 20; anchors.verticalCenter: parent.verticalCenter; agent: turn.who }
      Label { text: turn.who.toUpperCase(); color: turn.tone; font.pixelSize: 10; font.letterSpacing: 2.5 }
      Label { text: turn.stamp; color: Qt.alpha(turn.tone, 0.7); font.pixelSize: 9; font.letterSpacing: 1 }
    }

    Rectangle {
      width: parent.width
      height: line.implicitHeight + 14
      color: turn.mine ? Theme.highlight : Qt.tint(Theme.background, Qt.alpha(turn.tone, 0.1))
      Label {
        id: line
        anchors.verticalCenter: parent.verticalCenter
        x: turn.inset
        width: parent.width - 2 * turn.inset
        horizontalAlignment: turn.mine ? Text.AlignRight : Text.AlignLeft
        text: turn.mine ? turn.text : Omunculus.inline(turn.text)
        textFormat: turn.mine ? Text.PlainText : Text.MarkdownText
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
