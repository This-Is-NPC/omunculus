import QtQuick

// Notices are what a window tells, as a ToastStack shows them: each told
// notice is a new one, so one told again shows again. While `offline`, a
// pinned error says the server does not answer.
QtObject {
  id: root

  // Oldest first: {id, kind, text, pinned}, `kind` "info" or "error".
  property var items: []
  property bool offline: false
  property int nextId: 1
  property int offlineId: 0

  onOfflineChanged: {
    if (offline)
      offlineId = add("error", "The server does not answer", true)
    else
      dismiss(offlineId)
  }

  function tell(text, isError) { add(isError ? "error" : "info", text, false) }

  function add(kind, text, pinned) {
    const id = nextId++
    items = items.concat([{ id: id, kind: kind, text: text, pinned: pinned }])
    return id
  }

  function dismiss(id) {
    if (items.some(notice => notice.id === id))
      items = items.filter(notice => notice.id !== id)
  }
}
