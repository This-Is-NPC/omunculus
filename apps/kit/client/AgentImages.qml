import QtQuick
import Quickshell

// AgentImages keeps the agents' images of one project: each fetched once,
// by its SHA-256 as the config route gives it, into Quickshell's cache.
QtObject {
  id: root

  // The Http the images are fetched through, the project's socket and its
  // base path, and its agents as the config route lists them.
  required property Http http
  property string socket
  property string base
  property var agents: []

  // Image SHA-256 -> the file it was saved in, once fetched.
  property var files: ({})
  property var fetching: ({})

  // The file of an agent's image, as a url, or "" while it has none or it
  // is being fetched.
  function source(agent) {
    const entry = agents.find(each => each.name === agent)
    if (!entry || !entry.image)
      return ""
    if (files[entry.image])
      return "file://" + files[entry.image]
    if (!fetching[entry.image]) {
      fetching[entry.image] = true
      http.fetch(socket, base + "/agents/" + encodeURIComponent(agent) + "/image", Quickshell.cachePath("images/" + entry.image),
        file => files = Object.assign({}, files, { [entry.image]: file }))
    }
    return ""
  }
}
