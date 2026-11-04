pragma Singleton
import QtQuick

// Typing is whether text is being written: every text field marks it on each
// key, and the keys of the window that are not text wait until a second after.
QtObject {
  id: typing

  // True a second after the last key a text field saw.
  property bool idle: true

  function mark() {
    idle = false
    quiet.restart()
  }

  property Timer quiet: Timer {
    interval: 1000
    onTriggered: typing.idle = true
  }
}
