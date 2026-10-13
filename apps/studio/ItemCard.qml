pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// ItemCard edits one item of the config on its own — an agent, a model, a
// provider, or a whole table as the policy — as a draft of what the file holds
// for it, saved alone through the configure tool or put back. A rename is saved
// in the same write. A new item, not in the file yet, starts from `fresh`.
// While its draft is unchanged it follows the file; when the file changes under
// a changed draft, it saves no more until it is put back.
SettingsCard {
  id: card

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

  // Asks for its removal; the view confirms first.
  signal removing()
  // A new item removed before it was saved.
  signal dropped()

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
    const item = single ? section : section + "." + newName
    const from = !single && stored !== null && newName !== name ? name : ""
    Studio.configure(item, draft, from, () => saving = false, reason => {
      saving = false
      issue = reason
    })
  }

  Component.onCompleted: reset()
  onStoredChanged: if (!dirty || JSON.stringify(stored) === JSON.stringify(draft)) reset()

  title: single ? section : newName
  removable: !single
  removeTip: "remove " + (name || "this one")
  active: expanded || dirty
  onRemoved: stored === null ? dropped() : removing()

  actions: [
    Label {
      visible: card.dirty && !card.saving
      text: card.conflict ? "CHANGED IN THE FILE" : card.stored === null ? "NEW" : "UNSAVED"
      color: card.conflict ? Theme.warning : Theme.dim
      font.pixelSize: 9
      font.letterSpacing: 2
    },
    Chip {
      visible: card.dirty && card.stored !== null && !card.saving
      text: "DISCARD"
      tip: "back to what the file holds"
      onClicked: card.reset()
    },
    TraceButton {
      visible: card.dirty
      dense: true
      role: "progress"
      icon: "enter"
      text: card.saving ? "SAVING" : "SAVE"
      tip: card.conflict ? "the file changed: discard to read it again" : "write it into the project's config"
      busy: card.saving
      enabled: !card.conflict && card.nameIssue === ""
      onClicked: card.save()
    }
  ]

  FieldError {
    Layout.fillWidth: true
    text: card.issue
  }
}
