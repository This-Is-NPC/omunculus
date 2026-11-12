pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Tree.js" as Tree
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TreeOutline is the works as indented lineage rows (WorkLines), the chart's
// tree in the grammar of the chat: you and the agent that talks with you at
// L0, depth lifelines, a chevron to fold what a work handed down, parallel
// works as lanes. A row chosen emits chosen(work).
ListView {
  id: outline

  // The work picked.
  property string picked: ""
  // Works and folds opened (true) or closed (false) by hand.
  property var folds: ({})
  signal chosen(string work)
  signal opened(string work)

  readonly property real unit: Breakpoints.tight(width) ? Theme.size.mark : Theme.size.gutter
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  model: Tree.stream({ progress: Omunculus.progress, opened: folds, lead: true })
    .filter(row => ["you", "front", "work", "fold", "fork"].includes(row.kind))
  Accessible.role: Accessible.Tree
  Accessible.name: "the works"

  delegate: WorkLines {
    required property var modelData
    row: modelData
    width: outline.width
    unit: outline.unit
    origin: outline.unit
    picked: outline.picked
    onToggled: (key, open) => {
      const next = Object.assign({}, outline.folds)
      next[key] = open
      outline.folds = next
    }
    onChosen: work => outline.chosen(work)
    onOpened: work => outline.opened(work)
  }
}
