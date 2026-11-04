import QtQuick
import Quickshell

// Project is the project a window is on, on the server's local socket:
// whether the server answers, asked again every few seconds, the requests to
// it, and the notices the window shows. Opened with a socket and no
// project, it is on the server's registry, which that socket lists.
QtObject {
  id: root

  property string socket: Quickshell.env("OMUNCULUS_SOCKET")
  property string project: Quickshell.env("OMUNCULUS_PROJECT")
  readonly property bool registry: project === "" && socket !== ""
  readonly property string base: "/v1/projects/" + project
  property bool connected: false
  // The server did not answer the last time it was asked.
  property bool unreachable: false
  readonly property Notices notices: Notices { offline: root.unreachable }

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
    if (socket === "")
      tell("this window was opened without a server to ask", true)
    else
      check()
  }

  function check() {
    call("GET", "/v1/identity", null, false, () => {
      unreachable = false
      if (!connected) {
        connected = true
        reached()
      }
    }, () => {
      connected = false
      unreachable = true
    })
  }

  // Moves the window to another project of the registry, as {id, socket}:
  // not connected and with no notice until its socket answers.
  function switchTo(place) {
    project = place.id
    socket = place.socket
    connected = false
    unreachable = false
    notices.items = []
    check()
  }

  // Adds the project `id`, whose config is the file at `config`, to the
  // running server, which writes it into its registry. `failed` gets the
  // reason.
  function registerProject(id, config, done, failed) {
    call("POST", "/v1/projects", { id: id, config: config }, false, done, failed)
  }

  function tell(text, isError) { notices.tell(text, isError) }

  // One HTTP request on the project's socket, as `Http.call` makes it.
  function call(method, path, body, idempotent, done, failed) {
    http.call(socket, method, path, body, idempotent, done, failed)
  }
}
