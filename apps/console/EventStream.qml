import QtQuick
import Quickshell.Io

// EventStream is one of the server's WebSockets, read through curl on the
// project's socket, giving each JSON object its frames carry. curl writes
// each frame's payload as it comes, with nothing between them, so the bytes
// are split where an object closes. Each connection is a new process; one
// that ends while the stream is wanted connects again after a second, at the
// `path` it has then.
Item {
  id: stream

  property string socket: ""
  // The WebSocket's path, with the cursor it resumes after; read on each
  // connection.
  property string path: ""
  property bool wanted: false
  signal received(var event)

  // Connects now, at the path it has.
  function start() {
    wanted = true
    connect()
  }

  function stop() {
    wanted = false
    generation++
    link.active = false
  }

  property int generation: 0
  function connect() {
    generation++
    buffer = ""
    scanned = 0
    scanDepth = 0
    scanString = false
    scanEscape = false
    link.active = false
    link.active = wanted
  }

  // `buffer` starts at the object being read; `scanned` characters of it
  // have been read with the depth and string state below. The scan runs on
  // locals: reading a property converts its whole string on every access.
  property string buffer: ""
  property int scanned: 0
  property int scanDepth: 0
  property bool scanString: false
  property bool scanEscape: false
  function feed(data) {
    const text = buffer + data
    let depth = scanDepth
    let inString = scanString
    let escaped = scanEscape
    let start = 0
    for (let i = scanned; i < text.length; i++) {
      const c = text[i]
      if (inString) {
        if (escaped)
          escaped = false
        else if (c === "\\")
          escaped = true
        else if (c === "\"")
          inString = false
      } else if (c === "\"") {
        inString = true
      } else if (c === "{") {
        if (depth === 0)
          start = i
        depth++
      } else if (c === "}") {
        depth--
        if (depth === 0) {
          received(JSON.parse(text.slice(start, i + 1)))
          start = i + 1
        }
      }
    }
    buffer = text.slice(depth === 0 ? text.length : start)
    scanned = buffer.length
    scanDepth = depth
    scanString = inString
    scanEscape = escaped
  }

  Loader {
    id: link
    active: false
    sourceComponent: Process {
      readonly property int generation: stream.generation
      command: ["curl", "-sN", "--unix-socket", stream.socket, "ws://localhost" + stream.path]
      running: true
      stdout: SplitParser {
        splitMarker: ""
        onRead: data => stream.feed(data)
      }
      onExited: if (generation === stream.generation) reconnect.restart()
    }
  }

  Timer {
    id: reconnect
    interval: 1000
    onTriggered: if (stream.wanted) stream.connect()
  }
}
