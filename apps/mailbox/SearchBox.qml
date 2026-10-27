import QtQuick
import "kit/ui"

// SearchBox finds threads: `/` puts the keyboard in it,
// what is typed applies a quarter of a second after the last key, a trace runs
// meanwhile, Esc empties it or, already empty, goes on to the list, and Down
// or Enter goes on to the list too.
TextBox {
  id: box

  signal leave()

  dense: true
  placeholderText: "search threads  /"
  rightPadding: typing.running ? 66 : 10
  onTextChanged: typing.restart()

  Timer {
    id: typing
    interval: 250
    onTriggered: Mail.query = box.text.trim().toLowerCase()
  }

  LoadingTrace {
    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
    width: 48
    height: 12
    running: typing.running
  }

  Keys.onEscapePressed: {
    if (text !== "")
      text = ""
    else
      leave()
  }
  Keys.onDownPressed: leave()
  Keys.onReturnPressed: leave()
}
