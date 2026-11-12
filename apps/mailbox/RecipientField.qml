pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Mailbox.js" as Mailbox
import "kit/ui"

// RecipientField is the To of a message: the accounts chosen as chips, each
// with an x that takes it off (Backspace in the empty field takes the last),
// and a field to find another by typing a name or an address. The matches
// float under the field, never before something is typed, and never move the
// form; Esc or a click outside closes them. The address-book button at its
// right end floats every account in `candidates` to pick from, with a search.
// With `single`, a second account is refused, saying so.
RowLayout {
  id: field

  // The accounts chosen, as Mailbox.person makes them.
  property var chosen: []
  // Every account that can be written to.
  property var candidates: []
  property bool single: false
  property string placeholder: "name or address"
  // Why the last account picked was not taken; "" while nothing is wrong.
  property string refusal: ""

  readonly property var taken: chosen.map(item => item.address)
  readonly property var matches: Mailbox.complete(candidates, entry.text, taken).slice(0, 8)

  // Takes `person` as a recipient, unless the field holds one only and it is another.
  function add(person) {
    if (single && chosen.length > 0 && chosen[0].address !== person.address) {
      refusal = "A message goes to one agent. Remove " + chosen[0].name + " to write to " + person.name + "."
      return false
    }
    refusal = ""
    if (!taken.includes(person.address))
      chosen = chosen.concat([person])
    entry.text = ""
    suggestions.close()
    return true
  }

  function remove(address) {
    chosen = chosen.filter(item => item.address !== address)
    refusal = ""
    entry.forceActiveFocus()
  }

  function focusEntry() { entry.forceActiveFocus() }

  // Opens the matches while there are some to show, closes them else.
  function refresh() {
    if (matches.length > 0 && entry.activeFocus) {
      if (!suggestions.opened)
        suggestions.open()
    } else {
      suggestions.close()
    }
  }

  spacing: Theme.space.gap

  Item {
    id: frame
    Layout.fillWidth: true
    implicitHeight: Math.max(Theme.size.controlDense, flow.implicitHeight + 2 * Theme.space.tight)

    InputFrame { anchors.fill: parent; focused: entry.activeFocus }
    MouseArea { anchors.fill: parent; onClicked: entry.forceActiveFocus() }

    Flow {
      id: flow
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.tight; rightMargin: Theme.space.tight }
      spacing: Theme.space.tight

      Repeater {
        model: field.chosen
        delegate: Rectangle {
          id: chip
          required property var modelData
          implicitHeight: Theme.size.chip
          implicitWidth: row.implicitWidth + 2 * Theme.space.gap
          color: activeFocus ? Qt.alpha(Theme.primary, 0.12) : Qt.alpha(Theme.foreground, 0.04)
          border.color: activeFocus ? Theme.primary : Theme.line
          activeFocusOnTab: true
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
              field.remove(chip.modelData.address)
              event.accepted = true
            }
          }
          MouseArea { id: pill; anchors.fill: parent; hoverEnabled: true; onClicked: chip.forceActiveFocus() }
          Hint { active: pill.containsMouse; text: chip.modelData.address }
          Row {
            id: row
            anchors.centerIn: parent
            spacing: Theme.space.gap
            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: chip.modelData.name
              color: chip.activeFocus ? Theme.primary : Theme.foreground
              font.pixelSize: 12
            }
            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "close"
              size: 10
              color: gone.containsMouse ? Theme.error : Theme.dim
              MouseArea {
                id: gone
                anchors { fill: parent; margins: -Theme.space.gap }
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: field.remove(chip.modelData.address)
              }
            }
          }
        }
      }

      TextBox {
        id: entry
        width: Theme.size.control * 4
        dense: true
        background: null
        placeholderText: field.chosen.length === 0 ? (Mail.projects.length === 0 ? (Mail.connected ? "reading the agents" : "the server does not answer") : field.placeholder) : ""
        onTextEdited: field.refresh()
        onActiveFocusChanged: if (!activeFocus) suggestions.close()
        onAccepted: if (suggestions.opened) suggestions.pick(suggestions.current)
        Keys.onPressed: event => {
          Typing.mark()
          if (event.key === Qt.Key_Backspace && text === "" && field.chosen.length > 0) {
            field.remove(field.chosen[field.chosen.length - 1].address)
            event.accepted = true
          }
        }
        Keys.onEscapePressed: event => {
          event.accepted = suggestions.opened
          suggestions.close()
        }
        Keys.onDownPressed: if (suggestions.opened) suggestions.move(suggestions.current + 1)
        Keys.onUpPressed: if (suggestions.opened) suggestions.move(suggestions.current - 1)
      }
    }

    // The matches, floating under the field; the keyboard stays in the field.
    MenuPopup {
      id: suggestions
      minimumWidth: frame.width
      takesKeyboard: false
      entries: field.matches.map(item => ({ text: item.text }))
      onPicked: index => field.add(field.matches[index])
    }
  }

  IconButton {
    id: open
    name: "contacts"
    tip: "address book: every account you can write to"
    highlighted: book.opened
    onClicked: book.opened ? book.close() : book.open()

    AddressBook {
      id: book
      accounts: field.candidates
      taken: field.taken
      onChosen: person => field.add(person)
    }
  }
}
