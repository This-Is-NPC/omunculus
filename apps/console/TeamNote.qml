pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// TeamNote is a note a work's agent left on its work, where it was left: a
// quoted card, outlined, headed by the quote mark and NOTE FROM and the agent
// in its tone, with the time at its right, and the note in the body's size
// and full contrast. It is the team's news, not a message to you: only the
// front agent talks to the client, in bubbles. A long note shows six lines
// and unfolds by choosing its heading, or is unfolded by the thread. The
// newest note of a done conversation is its result: DELIVERED BY and the
// agent, in the success tone, whole and as wide as the thread. Its text is
// Prose: an address in it is a link.
Item {
  id: note

  required property string who
  required property string text
  property string stamp
  // The delivered result of a done conversation.
  property bool result: false

  // Unfolded by the thread; `chosen` flips it, the person's own fold.
  property bool unfolded: false
  property bool chosen: false
  readonly property bool open: unfolded !== chosen
  readonly property bool long: words.truncated || open && words.lineCount > 6

  implicitHeight: card.y + card.height + Theme.space.row

  // A note keeps a bubble's measure; the result takes the thread's width.
  SurfaceFrame {
    id: card
    y: Theme.space.tight
    width: note.result ? note.width : Math.min(620, note.width < Theme.size.measureFrom ? note.width : note.width * Theme.size.measure)
    height: content.implicitHeight + Theme.space.insetTop + Theme.space.inset
    variant: "outline"
    active: note.result
    tone: Theme.success
  }

  ColumnLayout {
    id: content
    anchors { left: card.left; right: card.right; top: card.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.gap

    Item {
      Layout.fillWidth: true
      implicitHeight: heading.implicitHeight
      activeFocusOnTab: note.long
      Accessible.role: Accessible.Button
      Accessible.name: note.who + (note.result ? " delivered: " : " noted: ") + note.text
      Keys.onPressed: event => {
        if (note.long && [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
          note.chosen = !note.chosen
          event.accepted = true
        }
      }

      RowLayout {
        id: heading
        anchors { left: parent.left; right: parent.right }
        spacing: Theme.space.tight
        Icon { name: note.result ? "check" : "quote"; size: Theme.type.kicker.size + 1; color: note.result ? Theme.success : Theme.dim }
        Label {
          text: note.result ? "DELIVERED BY" : "NOTE FROM"
          color: note.result ? Theme.success : Theme.dim
          font.pixelSize: Theme.type.kicker.size
          font.letterSpacing: Theme.type.kicker.tracking
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: note.who.toUpperCase()
          color: Omunculus.toneOf(note.who)
          font.pixelSize: Theme.type.kicker.size
          font.letterSpacing: Theme.type.kicker.tracking
          elide: Text.ElideRight
        }
        Label { text: note.stamp; color: Theme.faint; font.pixelSize: Theme.type.stamp.size; font.letterSpacing: Theme.type.stamp.tracking }
        Icon { visible: note.long; name: note.open ? "chevron-up" : "chevron-down"; size: Theme.type.kicker.size; color: Theme.dim }
      }
      MouseArea {
        anchors.fill: parent
        enabled: note.long
        cursorShape: note.long ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: note.chosen = !note.chosen
      }
      FocusRing { anchors.margins: -Theme.space.row }
    }

    Prose {
      id: words
      Layout.fillWidth: true
      source: Omunculus.inline(note.text)
      color: Theme.foreground
      font.pixelSize: Theme.type.body.size
      lineHeight: Theme.type.body.lineHeight
      wrapMode: Text.Wrap
      maximumLineCount: note.open || note.result ? 1000 : 6
      elide: Text.ElideRight
    }
  }
}
