pragma ComponentBehavior: Bound
import QtQuick
import "kit/client/Progress.js" as Progress
import "kit/client/Tree.js" as Tree
import "kit/ui"

// WorkLines is a "you", "front", "work", "fold" or "fork" row of Tree.stream
// as the hierarchy draws it, in the chat and in the tree: a LineageRow, or the
// lanes of a ForkBlock. Give it the `row`, the `unit` and `origin` of the
// column geometry and the `scope` (the work the view is kept to, "" for
// none). Signals: toggled(key, open) a work or a fold to open or close,
// opened(work) the arrow of a work, chosen(work) a work or a lane picked.
Loader {
  id: lines
  required property var row
  property real unit: Theme.size.gutter
  property real origin: 0
  property string scope: ""
  // The work picked, shown washed.
  property string picked: ""
  signal toggled(string key, bool open)
  signal opened(string work)
  signal chosen(string work)

  height: item ? item.implicitHeight : 0
  sourceComponent: ({ you: you, front: front, work: work, fold: fold, fork: fork })[row.kind] || null

  // L0: the person, and the agent that talks with them.
  Component {
    id: you
    LineageRow {
      width: lines.width
      stem: lines.row.stem
      unit: lines.unit
      origin: lines.origin
      agent: "you"
      tone: Theme.primary
      linked: false
    }
  }

  Component {
    id: front
    LineageRow {
      readonly property var look: Tree.frontState(lines.row.front)
      width: lines.width
      stem: lines.row.stem
      unit: lines.unit
      origin: lines.origin
      agent: lines.row.front.agent
      tone: Omunculus.toneOf(agent)
      title: lines.row.front.doing
      state: look.state
      stateText: look.text
      linked: false
    }
  }

  Component {
    id: work
    LineageRow {
      readonly property var node: lines.row.node
      readonly property var look: Tree.stateOf(node)
      width: lines.width
      depth: lines.row.depth
      rails: lines.row.rails
      last: lines.row.last
      stem: lines.row.stem
      unit: lines.unit
      origin: lines.origin
      agent: node.agent
      tone: Omunculus.toneOf(node.agent)
      title: node.title
      // Folded, what it handed down.
      meta: lines.row.kids > 0 && !lines.row.open ? Progress.below(Progress.kidsOf(node)) : ""
      state: look.state
      stateText: look.text
      folds: lines.row.kids > 0
      open: lines.row.open
      picked: node.work === lines.picked
      linked: node.work !== lines.scope
      onToggled: lines.toggled(node.work, !lines.row.open)
      onChosen: lines.chosen(node.work)
      onOpened: lines.opened(node.work)
    }
  }

  // Finished works gathered in one line.
  Component {
    id: fold
    LineageRow {
      readonly property var nodes: lines.row.nodes
      readonly property var last: nodes[nodes.length - 1]
      readonly property var look: Tree.stateOf(last)
      width: lines.width
      depth: lines.row.depth
      rails: lines.row.rails
      unit: lines.unit
      origin: lines.origin
      agent: Array.from(new Set(nodes.map(node => node.agent))).join(", ")
      tone: Omunculus.toneOf(last.agent)
      title: (nodes.length > 1 ? nodes.length + " folded" + Theme.type.meta.separator : "") + last.title
      meta: lines.row.entries + (lines.row.entries === 1 ? " entry" : " entries")
      state: look.state
      stateText: look.text
      folds: true
      open: lines.row.unfolded
      linked: nodes.length === 1
      onToggled: lines.toggled(lines.row.key, !lines.row.unfolded)
      onChosen: lines.toggled(lines.row.key, !lines.row.unfolded)
      onOpened: lines.opened(last.work)
    }
  }

  // Works that ran at once.
  Component {
    id: fork
    ForkBlock {
      width: lines.width
      depth: lines.row.depth
      rails: lines.row.rails
      last: lines.row.last
      unit: lines.unit
      origin: lines.origin
      summary: lines.row.summary
      lanes: lines.row.nodes.map(node => ({
        work: node.work, agent: node.agent, tone: Omunculus.toneOf(node.agent), title: node.title,
        state: Tree.stateOf(node).state, stateText: Tree.stateOf(node).text
      }))
      onOpened: work => lines.chosen(work)
    }
  }
}
