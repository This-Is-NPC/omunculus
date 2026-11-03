import QtQuick

// ItemDraft is the draft of one item of the config — an agent, a model, a
// provider, or a whole table as the policy — as the file holds it, saved alone
// through the config routes or put back. A rename is saved in the same write.
// A new item, not in the file yet, starts from `fresh`. While its draft is
// unchanged it follows the file; when the file changes under a changed draft,
// it saves no more until it is put back.
QtObject {
  id: item

  // "agents", "models", ...; with `single`, the item is the section itself.
  required property string section
  property string name: ""
  property bool single: false
  // What the file holds for it, or null for an item not saved yet.
  property var stored: null
  property var fresh: ({})
  // The names taken in its section, for a rename.
  property var taken: []

  property var draft: ({})
  property var base: null
  property string newName: name
  property string issue: ""
  property bool saving: false

  readonly property bool dirty: stored === null || newName !== name || JSON.stringify(draft) !== JSON.stringify(base)
  readonly property bool conflict: stored !== null && base !== null && JSON.stringify(stored) !== JSON.stringify(base)
  // Why the new name cannot be, or "".
  readonly property string nameIssue: single || newName === name ? ""
    : !/^[A-Za-z0-9_-]+$/.test(newName) ? "letters, digits, _ and - only"
    : taken.includes(newName) ? newName + " is taken"
    : ""

  // Saved: `name` is what it is saved as.
  signal saved(string name)

  function clone(value) { return value === null || value === undefined ? null : JSON.parse(JSON.stringify(value)) }

  function reset() {
    base = clone(stored)
    draft = clone(stored) || clone(fresh)
    newName = name
    issue = ""
  }

  // Sets the value at `path` of the draft, or removes it for null.
  function put(path, value) {
    const next = clone(draft)
    let table = next
    for (const key of path.slice(0, -1)) {
      if (table[key] === undefined || typeof table[key] !== "object" || Array.isArray(table[key]))
        table[key] = {}
      table = table[key]
    }
    if (value === null)
      delete table[path[path.length - 1]]
    else
      table[path[path.length - 1]] = value
    draft = next
    issue = ""
  }

  function replace(table) {
    draft = clone(table)
    issue = ""
  }

  function save() {
    if (saving || conflict || nameIssue !== "")
      return
    saving = true
    issue = ""
    const target = single ? section : section + "." + newName
    const from = !single && stored !== null && newName !== name ? name : ""
    const as = newName
    Studio.configure(target, draft, from, () => {
      saving = false
      saved(as)
    }, reason => {
      saving = false
      issue = reason
    })
  }

  Component.onCompleted: reset()
  onStoredChanged: if (!dirty || JSON.stringify(stored) === JSON.stringify(draft)) reset()
}
