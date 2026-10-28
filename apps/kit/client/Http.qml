import QtQuick
import Quickshell
import Quickshell.Io

// HTTP requests to the server's local sockets, each through a curl process.
QtObject {
  id: root

  // Why a request failed, for a request given no `failed` of its own.
  signal refused(string reason)

  function key() {
    let value = ""
    for (let i = 0; i < 32; i++)
      value += Math.floor(Math.random() * 16).toString(16)
    return value
  }

  // One request to the socket `on`; `done` gets the decoded JSON of a 2xx
  // answer, and `failed`, when given, the reason of any other outcome.
  function call(on, method, path, body, idempotent, done, failed) {
    const args = ["curl", "-sS", "--unix-socket", on, "-X", method, "-H", "accept: application/json"]
    if (body !== null)
      args.push("-H", "content-type: application/json", "--data-binary", JSON.stringify(body))
    if (idempotent)
      args.push("-H", "Idempotency-Key: " + key())
    args.push("-w", "\n%{http_code}", "http://localhost" + path)
    run(args, on, done, failed)
  }

  // Runs the tool `name` with `args` on the socket `on`, as the local user;
  // `done` gets its output, and `failed`, when given, why it failed.
  function command(on, name, args, done, failed) {
    call(on, "POST", "/v1/call", { name: name, args: args }, false, data => done(data.output), failed)
  }

  // The setup of the project on the socket `on`, as the config tool prints it.
  function setup(on, done, failed) {
    command(on, "config", { whole: true }, output => done(JSON.parse(output)), failed)
  }

  // Runs `command`, which prints an answer and its status as curl -w does
  // above, and reads it as `call` does.
  function run(command, on, done, failed) {
    request.createObject(root, { command: command, on: on, done: done, failed: failed || null })
  }

  // A POST of `body` as `call` makes it, with the files at the paths `files`
  // lists attached when there are any, through post-with-files.
  function post(on, path, body, files, done, failed) {
    if (!files || files.length === 0)
      return call(on, "POST", path, body, true, done, failed)
    run([script("post-with-files"), on, path, key(), JSON.stringify(body)].concat(files), on, done, failed)
  }

  // Saves the file attached in a conversation that `path` answers on the
  // socket `on` to the downloads directory and opens it, through
  // open-attachment.
  function openAttachment(on, path, file) {
    Quickshell.execDetached([script("open-attachment"), on, path, file.name, file.sha256])
  }

  // The path of a script beside this file.
  function script(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  // Saves what `path` answers on the socket `on` into `file`; `done` gets
  // the file once it holds a 2xx answer, and nothing is said otherwise.
  function fetch(on, path, file, done) {
    download.createObject(root, {
      command: ["curl", "-sS", "--unix-socket", on, "--create-dirs", "-o", file, "-w", "%{http_code}", "http://localhost" + path],
      file: file, done: done
    })
  }

  property Component download: Component {
    Process {
      id: saving
      property string file
      property var done: null
      running: true
      stdout: StdioCollector {
        onStreamFinished: {
          const status = parseInt(text)
          if (status >= 200 && status < 300)
            saving.done(saving.file)
          Qt.callLater(() => saving.destroy())
        }
      }
    }
  }

  property Component request: Component {
    Process {
      id: process
      property string on
      property var done: null
      property var failed: null
      running: true
      stdout: StdioCollector {
        onStreamFinished: {
          const split = text.lastIndexOf("\n")
          const status = parseInt(text.slice(split + 1))
          const payload = text.slice(0, split)
          if (status >= 200 && status < 300) {
            process.done(payload === "" ? {} : JSON.parse(payload))
          } else {
            let reason = "the server does not answer on " + process.on
            try {
              const error = JSON.parse(payload)
              reason = error.message || error.error
            } catch (e) {}
            if (process.failed)
              process.failed(reason)
            else
              root.refused(reason)
          }
          Qt.callLater(() => process.destroy())
        }
      }
    }
  }
}
