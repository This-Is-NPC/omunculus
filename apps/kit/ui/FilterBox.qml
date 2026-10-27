import QtQuick

// FilterBox is a dense field whose text applies, as `applied`, a quarter of a
// second after the last change, a trace running meanwhile. Enter applies it at
// once and leaves; Esc empties it, applying the empty text, or, already
// empty, leaves; Down leaves too.
TextBox {
  id: box

  signal applied(string value)
  signal leave()

  dense: true
  rightPadding: typing.running ? 66 : 10
  onTextChanged: typing.restart()

  Timer {
    id: typing
    interval: 250
    onTriggered: box.applied(box.text)
  }

  LoadingTrace {
    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
    width: 48
    height: 12
    running: typing.running
  }

  Keys.onEscapePressed: {
    if (text === "")
      return leave()
    clear()
    typing.stop()
    applied("")
  }
  Keys.onDownPressed: leave()
  Keys.onReturnPressed: {
    typing.stop()
    applied(text)
    leave()
  }
}
