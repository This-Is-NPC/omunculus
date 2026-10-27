import QtQuick
import Quickshell

// Project is the project a window was opened on, on the server's local
// socket: whether the server answers, asked again every few seconds, the
// requests to it, and the last message the window shows.
QtObject {
  id: root

  property string socket: Quickshell.env("OMUNCULUS_SOCKET")
  property string project: Quickshell.env("OMUNCULUS_PROJECT")
  readonly property string base: "/v1/projects/" + project
  property bool connected: false
  property string message: ""
  property bool messageIsError: false
  // How many messages were told, so one told again shows again.
  property int noticeCount: 0

  // The server answers, the first time or after it did not.
  signal reached()

  readonly property Http http: Http {
    onRefused: reason => root.tell(reason, true)
  }

  property Timer poll: Timer {
    interval: 5000
    repeat: true
    running: root.socket !== ""
    onTriggered: root.check()
  }

  Component.onCompleted: {
    if (socket === "" || project === "")
      tell("this window was opened without a project to show", true)
    else
      check()
  }

  function check() {
    call("GET", "/v1/identity", null, false, () => {
      if (!connected) {
        connected = true
        reached()
      }
    }, () => connected = false)
  }

  function tell(text, isError) {
    message = text
    messageIsError = isError
    noticeCount++
  }

  // One HTTP request on the project's socket, as `Http.call` makes it.
  function call(method, path, body, idempotent, done, failed) {
    http.call(socket, method, path, body, idempotent, done, failed)
  }
}
