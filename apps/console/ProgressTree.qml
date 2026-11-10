pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui/focus.js" as Focus
import "kit/client/Progress.js" as Progress
import "kit/client/Requests.js" as Requests
import "kit/client/Time.js" as Time

// ProgressTree is who works on the conversation, compact, for the chat's
// progress view: what waits on you, then each root work — newest open first,
// as Progress orders them — with its title, start and length, its stages one
// per row, and under each stage the works handed down while it was current,
// nested by level. Siblings run in parallel under one heading. A done stage,
// and a done, cancelled or coming work, keeps what is below it folded until
// unfolded, unless a question waiting on you climbed from there; the done
// and cancelled works of each place fold into one row, "✓ 2 sub-works done ·
// 18 min · 9 in all". ↑/↓ move
// between rows, → unfolds, ← folds, Enter opens a work's details or folds a
// row, Esc leaves.
Item {
  id: tree

  // Omunculus.progress, or null.
  property var progress: null

  signal answer(string id)
  signal openThread(string work)
  signal openLog(string work)
  signal openTeam(string work)
  signal escaped()

  readonly property real now: Omunculus.tick
  readonly property real indent: Breakpoints.indent(width)
  // Folds the reader chose, by row key, over each row's default; the works
  // whose details show; the row the keyboard is on, and whether the
  // keyboard is in the tree, kept across the rebuilds of its rows.
  property var folds: ({})
  property var opened: ({})
  property string current: ""
  property bool holding: false

  readonly property var active: {
    const on = {}
    for (const step of progress ? progress.path : [])
      on[step.work] = true
    return on
  }

  function folded(key, otherwise) { return folds[key] === undefined ? otherwise : folds[key] }
  function toggle(key, otherwise) {
    const next = Object.assign({}, folds)
    next[key] = !folded(key, otherwise)
    folds = next
  }
  function open(key) {
    const next = Object.assign({}, opened)
    next[key] = !opened[key]
    opened = next
  }

  // The rows to draw, in order: {kind, key, level, ...}.
  readonly property var rows: {
    const out = []
    if (!progress)
      return out
    // The open works of a place, then those done or cancelled folded into
    // one row, unless a question of yours climbed from one of them; a done
    // stage unfolded, `whole`, lists them all.
    function place(parent, kids, level, whole) {
      let group = null
      for (const kid of whole ? kids : kids.filter(kid => !Progress.closed(kid.state))) {
        const found = parent.groups.find(each => each.parallel && each.nodes.some(node => node.work === kid.work)) || null
        if (found && found !== group) {
          const key = "group:" + found.nodes[0].work
          out.push({ kind: "group", key: key, level: level, text: Progress.together(found), folds: true, folded: folded(key, false), fold: false })
        }
        group = found
        if (found && folded("group:" + found.nodes[0].work, false))
          continue
        work(kid, level)
      }
      const finished = whole ? [] : kids.filter(kid => Progress.closed(kid.state))
      if (finished.length === 0)
        return
      const key = "done:" + parent.work + ":" + finished[0].work
      const quiet = !finished.some(kid => kid.below !== "")
      const shut = folded(key, quiet)
      out.push({ kind: "done", key: key, level: level, text: Progress.finished(finished), folds: true, folded: shut, fold: quiet })
      if (!shut)
        finished.forEach(kid => work(kid, level))
    }
    function work(node, level) {
      const kids = Progress.kidsOf(node)
      // Folded unless a question of yours climbed from below it.
      const quiet = ["done", "cancelled", "up-next"].includes(node.state) && node.below === ""
      const shut = kids.length > 0 && folded(node.work, quiet)
      out.push({ kind: "node", key: node.work, level: level, node: node, folds: kids.length > 0, folded: shut, fold: quiet })
      if (!shut)
        place(node, kids, level + 1)
    }

    for (const ask of progress.forYou)
      out.push({ kind: "needs", key: "ask:" + ask.id, level: 0, ask: ask })
    const roots = progress.roots
    if (roots.length === 0 && progress.state !== "idle" && progress.now.agent)
      out.push({ kind: "now", key: "now", level: 0 })
    for (const root of roots) {
      out.push({ kind: "head", key: "head:" + root.work, level: 0, node: root })
      const steps = root.steps
      if (steps.length === 0) {
        place(root, Progress.kidsOf(root), 1)
        continue
      }
      steps.forEach((step, at) => {
        const key = root.work + "#" + at
        const kids = step.children
        const quiet = step.status === "done" && !kids.some(kid => kid.below !== "" || kid.state === "needs-you")
        const shut = kids.length > 0 && folded(key, quiet)
        out.push({ kind: "stage", key: key, level: 0, node: root, step: step, folds: kids.length > 0, folded: shut, fold: quiet })
        if (!shut) {
          place(root, kids, 1, step.status === "done")
        } else {
          const done = kids.filter(kid => kid.state === "done").length
          out.push({ kind: "more", key: key + "+", level: 1, of: key, fold: quiet,
            text: kids.length + (kids.length === 1 ? " sub-work" : " sub-works") + (done === kids.length ? " done" : done > 0 ? " · " + done + " done" : "") + Progress.inAll(kids).map(text => " · " + text).join("") })
        }
      })
    }
    return out
  }

  // The keyboard to the next row that does something, by `by` rows.
  function move(from, by) {
    for (let at = from + by; at >= 0 && at < rows.length; at += by)
      if (!["head", "now"].includes(rows[at].kind)) {
        lines.itemAt(at).forceActiveFocus()
        return
      }
  }

  // A rebuild drops the focused row: the keyboard goes back to its key's
  // row, unless it went elsewhere meanwhile, outside the tree and its
  // containers.
  function settle() {
    const item = Window.activeFocusItem
    if (item && !Focus.within(item, tree) && !Focus.within(tree, item))
      holding = false
  }
  function regain() {
    if (!holding || Focus.within(Window.activeFocusItem, tree))
      return
    const at = rows.findIndex(row => row.key === current)
    if (at >= 0)
      lines.itemAt(at).forceActiveFocus()
  }
  onRowsChanged: Qt.callLater(regain)

  implicitHeight: body.implicitHeight

  Column {
    id: body
    width: tree.width
    spacing: Theme.space.line

    Label {
      width: parent.width
      visible: tree.rows.length === 0
      text: "No one is working on this conversation yet."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }

    Repeater {
      id: lines
      model: tree.rows
      delegate: FocusScope {
        id: entry
        required property var modelData
        required property int index
        readonly property string key: modelData.key
        readonly property real inset: Math.min(modelData.level, 3) * tree.indent

        width: body.width
        height: shown.item ? shown.item.implicitHeight : 0
        activeFocusOnTab: !["node", "head", "now"].includes(modelData.kind)
        onActiveFocusChanged: {
          if (activeFocus) {
            tree.current = key
            tree.holding = true
          } else {
            Qt.callLater(tree.settle)
          }
        }

        function enter() {
          const kind = modelData.kind
          if (kind === "node")
            tree.open(key)
          else if (kind === "needs")
            tree.answer(modelData.ask.id)
          else if (kind === "more")
            tree.toggle(modelData.of, modelData.fold)
          else if (modelData.folds)
            tree.toggle(key, modelData.fold)
        }
        Keys.onUpPressed: tree.move(index, -1)
        Keys.onDownPressed: tree.move(index, 1)
        Keys.onRightPressed: if (modelData.folds && modelData.folded) tree.toggle(key, modelData.fold)
        Keys.onLeftPressed: if (modelData.folds && !modelData.folded) tree.toggle(key, modelData.fold)
        Keys.onReturnPressed: enter()
        Keys.onSpacePressed: enter()
        Keys.onEscapePressed: tree.escaped()

        // The nesting glyph; past level 3 the indent stops and it says the level.
        Label {
          visible: entry.modelData.level > 0
          x: entry.inset - tree.indent
          y: 6
          text: entry.modelData.level > 3 ? "↳" + entry.modelData.level : "↳"
          color: Theme.dim
          font.pixelSize: 11
        }

        Loader {
          id: shown
          x: entry.inset + (entry.modelData.level > 3 ? 12 : 0)
          width: entry.width - x
          focus: true
          sourceComponent: ({ needs: needsRow, now: nowRow, head: headRow, stage: stageRow, group: foldRow, more: foldRow, done: foldRow })[entry.modelData.kind] || nodeRow
        }

        Component {
          id: nodeRow
          ProgressNode {
            node: entry.modelData.node
            focus: true
            active: tree.active[entry.key] === true
            expanded: tree.opened[entry.key] === true
            folds: entry.modelData.folds
            folded: entry.modelData.folded
            onToggled: tree.open(entry.key)
            onFoldToggled: tree.toggle(entry.key, entry.modelData.fold)
            onOpenThread: work => tree.openThread(work)
            onOpenLog: work => tree.openLog(work)
            onOpenTeam: work => tree.openTeam(work)
          }
        }

        // What waits on you: who asks, the question's first line, ANSWER.
        Component {
          id: needsRow
          SurfaceFrame {
            tone: Theme.warning
            active: true
            implicitHeight: needs.implicitHeight + Theme.space.insetTop * 2
            ColumnLayout {
              id: needs
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
              spacing: Theme.space.tight
              RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.tight
                Icon { name: Requests.audiences[entry.modelData.ask.audience].icon; size: 12; color: Theme.warning }
                Label {
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  text: (Requests.audiences[entry.modelData.ask.audience].text + " · " + entry.modelData.ask.asker + " asks").toUpperCase()
                  color: Theme.warning
                  font.pixelSize: Theme.type.kicker.size
                  font.letterSpacing: Theme.type.kicker.tracking
                  elide: Text.ElideRight
                }
              }
              Label {
                Layout.fillWidth: true
                text: entry.modelData.ask.question.split("\n")[0]
                color: Theme.foreground
                font.pixelSize: Theme.type.cardBody.size
                lineHeight: Theme.type.cardBody.lineHeight
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }
              // Urgent, never the main: its tone says so.
              TraceButton {
                role: "progress"
                dense: true
                tone: Theme.warning
                text: "ANSWER"
                icon: "enter"
                tip: "the question, to answer it"
                onClicked: tree.answer(entry.modelData.ask.id)
              }
            }
          }
        }

        // A run with no work yet, as the front desk's.
        Component {
          id: nowRow
          RowLayout {
            id: run
            readonly property var now: tree.progress.now
            spacing: Theme.space.tight
            Label {
              Layout.maximumWidth: run.width * 0.4
              text: run.now.agent
              color: Omunculus.toneOf(run.now.agent)
              font.pixelSize: 12
              font.bold: true
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: run.now.doing + (run.now.since !== null ? " · " + Progress.clock(Math.max(0, Math.round(tree.now - run.now.since))) : "")
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }

        // A root work's title, start, length and agents.
        Component {
          id: headRow
          ColumnLayout {
            id: head
            readonly property var node: entry.modelData.node
            readonly property var work: Omunculus.work(node.work)
            spacing: Theme.space.row
            Label {
              Layout.fillWidth: true
              Layout.topMargin: Theme.space.tight
              text: head.node.title
              color: Theme.foreground
              font.pixelSize: 13
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
            Label {
              Layout.fillWidth: true
              text: {
                const branch = head.node.branch
                const parts = []
                if (head.work && head.work.created_at)
                  parts.push("Started " + Time.clock(head.work.created_at, tree.now * 1000))
                parts.push(head.node.finishedIn ? "took " + Progress.span(head.node.finishedIn) : Progress.span(branch.seconds))
                if (branch.agents > 1)
                  parts.push(branch.agents + " agents")
                return parts.join(" · ")
              }
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }

        // One stage of a root work: its mark and name, its agent and time.
        Component {
          id: stageRow
          Rectangle {
            id: stage
            readonly property var step: entry.modelData.step
            readonly property bool now: step.status === "current"
            readonly property int round: now ? entry.modelData.node.round : 0
            readonly property string time: step.seconds > 0 ? Progress.span(step.seconds) : ""
            implicitHeight: Theme.size.rule
            color: entry.activeFocus || stageHover.hovered ? Theme.highlight : "transparent"
            HoverHandler { id: stageHover }
            TapHandler { onTapped: { entry.forceActiveFocus(); entry.enter() } }
            RowLayout {
              anchors { fill: parent; leftMargin: Theme.space.line; rightMargin: Theme.space.line }
              spacing: Theme.space.tight
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: (({ done: "✓ ", current: "● " })[stage.step.status] || "○ ") + stage.step.name
                  + (stage.round > 0 ? " · round " + stage.round : "")
                color: stage.now ? Theme.primary : stage.step.status === "done" ? Theme.foreground : Theme.dim
                font.pixelSize: 12
                font.bold: stage.now
                elide: Text.ElideRight
              }
              Label {
                Layout.maximumWidth: stage.width * 0.55
                text: {
                  const said = stage.now ? (stage.time !== "" ? stage.time + " so far" : "")
                    : stage.step.again ? stage.time + ", due again" : stage.step.status === "done" ? stage.time : ""
                  return stage.step.agent + (said !== "" ? " · " + said : "")
                }
                color: Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Icon {
                visible: entry.modelData.folds
                name: entry.modelData.folded ? "chevron-right" : "chevron-down"
                size: 12
                color: Theme.dim
              }
            }
            FocusRing { shown: entry.activeFocus }
          }
        }

        // The heading of works that run side by side, a done stage's works,
        // folded, or the done and cancelled works of a place.
        Component {
          id: foldRow
          Rectangle {
            implicitHeight: Theme.size.rule
            color: entry.activeFocus || foldHover.hovered ? Theme.highlight : "transparent"
            HoverHandler { id: foldHover }
            TapHandler { onTapped: { entry.forceActiveFocus(); entry.enter() } }
            RowLayout {
              anchors { fill: parent; leftMargin: Theme.space.line; rightMargin: Theme.space.line }
              spacing: Theme.space.tight
              Label {
                visible: entry.modelData.kind === "done"
                text: "✓"
                color: Theme.success
                font.pixelSize: Theme.type.tab.size
              }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: entry.modelData.text
                color: entry.modelData.kind === "group" ? Theme.foreground : Theme.dim
                font.pixelSize: 11
                elide: Text.ElideRight
              }
              Icon {
                name: entry.modelData.kind === "more" || entry.modelData.folded ? "chevron-right" : "chevron-down"
                size: 12
                color: Theme.dim
              }
            }
            FocusRing { shown: entry.activeFocus }
          }
        }
      }
    }
  }
}
