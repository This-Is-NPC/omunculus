pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// AddressBook floats under the button that opens it, aligned to its right
// edge: a search box over every account in `accounts` that is not in `taken`,
// each a name and its address. Typing narrows the list, Up and Down move,
// Enter or a click picks; Esc or a click outside closes it.
PopupFrame {
  id: book

  // The accounts to list, as Mailbox.person makes them, and the addresses
  // already chosen.
  property var accounts: []
  property var taken: []
  signal chosen(var person)

  readonly property var shown: Mailbox.suggest(accounts, search.text).filter(item => !taken.includes(item.address))
  property int current: 0

  function pick(person) {
    book.close()
    book.chosen(person)
  }

  width: Math.min(Theme.size.control * 8, Math.max(0, parent.Window.width - 2 * margins))
  x: parent.width - width
  padding: Theme.space.line
  height: Math.min(Theme.size.control * 8, bar.implicitHeight + Math.max(1, list.contentHeight) + Theme.space.gap + 2 * padding)
  onAboutToShow: { search.text = ""; current = 0 }
  onOpened: search.forceActiveFocus()

  ColumnLayout {
    id: bar
    anchors.fill: parent
    spacing: Theme.space.tight

    TextBox {
      id: search
      Layout.fillWidth: true
      dense: true
      placeholderText: "search name or address"
      onTextEdited: book.current = 0
      Keys.onPressed: Typing.mark()
      Keys.onDownPressed: book.current = Math.min(book.shown.length - 1, book.current + 1)
      Keys.onUpPressed: book.current = Math.max(0, book.current - 1)
      onAccepted: if (book.shown.length > 0) book.pick(book.shown[book.current])
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: book.shown
      currentIndex: book.current
      boundsBehavior: Flickable.StopAtBounds
      delegate: ChoiceRow {
        required property var modelData
        required property int index
        width: list.width
        text: modelData.text
        current: index === book.current
        onPicked: book.pick(modelData)
      }
      Label {
        anchors { left: parent.left; top: parent.top; leftMargin: Theme.space.gap; topMargin: Theme.space.tight }
        visible: book.shown.length === 0
        text: book.accounts.length === 0 ? "no account to write to yet" : "no account matches"
        color: Theme.dim
        font.pixelSize: Theme.type.body.size
      }
    }
  }
}
