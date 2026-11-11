pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Tree.js" as Tree
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TreePage is the TREE page: the conversation's works in the order they were
// made (Tree.rows, a TreeNode each) and the work picked in full (NodeDetail).
// The agent that talks with the person is the root when its works are other
// agents'; each work sits under the work that handed it down, every level
// deep, lines drawing who handed what to whom, and each says its agent, its
// stage, its state and how long it has run. A work with a work still open
// below it shows its works, and so does a root; the rest stay folded behind
// their chevron. A click on a work, or Enter, opens its runs and their steps
// inside it; a second Enter, or its DETAIL, opens the work in full as a page
// over the tree, and BACK returns to the same row. Chips keep the works that
// need you or work, with the works above them; `/` filters by title, agent
// or stage. A ⇡/⇣ badge goes to the other end of its request, lights both and
// opens the request in the detail. ↑/↓ move, → opens or goes to the first row
// under, ← folds or goes to the parent, `[`/`]` change the detail's tab, Esc
// goes detail, tree, back.
FocusScope {
  id: team

  // The work picked, or "" for none.
  property string picked: ""
  signal leave()
  signal openLog(string work)
  // A request's decision, over the page: to answer it or, `escalating`, to
  // raise it to whoever decides above you.
  signal decide(string id, bool escalating)

  readonly property var progress: Omunculus.progress
  readonly property var flat: progress ? progress.flat : []
  readonly property var byWork: Tree.index(flat)
  readonly property var pickedNode: byWork[picked] || null

  // Whether the work picked shows in full, as a page over the tree.
  property bool detailOpen: false

  // The tree's filters: "all", "needs-you" or "working", and the text.
  property string chip: "all"
  property string filter: ""
  // The works opened (true) or closed (false) by hand, and those whose runs
  // show inside them.
  property var opened: ({})
  property var running: ({})
  // The two works at the ends of the request whose badge was picked.
  property var linked: []

  readonly property int needsYou: progress ? progress.forYou.length : 0
  readonly property int working: flat.filter(node => node.state === "working").length + (progress && progress.front && progress.front.state === "working" ? 1 : 0)

  readonly property var rows: Tree.rows(progress, opened, Tree.kept(flat, chip, filter))
  function rowOf(key) { return rows.findIndex(row => row.key === key) }

  function setOpen(key, value) {
    const next = Object.assign({}, opened)
    next[key] = value
    opened = next
  }
  // Shows a work's runs inside it, or puts them away.
  function setRuns(key, value) {
    const next = Object.assign({}, running)
    next[key] = value
    running = next
  }

  // The way down to a work, outermost first.
  function trailOf(work) {
    const chain = []
    for (let at = byWork[work]; at; at = byWork[at.parent])
      chain.unshift(at)
    return chain
  }

  // Picks a work: the works above it and the fold it is in open, its row
  // comes into view.
  function pick(work) {
    picked = work
    unfold()
    reveal.key = work
    reveal.restart()
  }
  // The work picked last shown: the person may fold it away again.
  property string shown: ""
  function unfold() {
    if (!byWork[picked])
      return
    if (rowOf(picked) < 0)
      opened = Tree.reveal(progress, opened, picked)
    shown = picked
  }

  // A row chosen: picked, its runs shown inside it or put away.
  function choose(work) {
    pick(work)
    setRuns(work, running[work] !== true)
  }

  // Opens a work in full, as a page over the tree.
  function open(work) {
    pick(work)
    detailOpen = true
  }

  // A request's badge: both its ends lit, the other end picked, the request
  // open in the detail.
  function requestPicked(from, id) {
    const asker = flat.find(node => node.asks.some(ask => ask.id === id))
    const ask = asker ? asker.asks.find(each => each.id === id) : null
    const decider = ask && ask.toWork ? ask.toWork : ""
    linked = [asker ? asker.work : "", decider].filter(work => work !== "")
    const other = from === (asker ? asker.work : "") ? decider : asker ? asker.work : ""
    open(other !== "" ? other : from)
    detail.show("requests")
  }

  // The request waiting on you nearest the work picked — its own, above it,
  // below it — else the newest.
  function nearestForYou() {
    const human = node => node.asks.filter(ask => ask.forYou).map(ask => ask.id)
    for (let at = pickedNode; at; at = byWork[at.parent])
      if (human(at).length > 0)
        return human(at)[0]
    const below = pickedNode ? flat.filter(node => trailOf(node.work).includes(pickedNode)) : []
    for (const node of below)
      if (human(node).length > 0)
        return human(node)[0]
    const newest = progress ? progress.forYou[progress.forYou.length - 1] : null
    return newest ? newest.id : ""
  }

  // Writes to the agent of the work picked or, `noting`, leaves it a note.
  function write(noting) {
    if (picked === "")
      return
    detailOpen = true
    detail.write(noting)
  }
  function showTab(name) {
    if (picked === "")
      return
    detailOpen = true
    detail.show(name)
  }
  function focusFilter() {
    detailOpen = false
    filterLater.restart()
  }

  // Lets go of one thing: the detail page, then the keyboard in the detail;
  // false when there is nothing more to let go of.
  function back() {
    if (detailOpen) {
      detailOpen = false
      treeLater.restart()
      return true
    }
    if (detail.activeFocus) {
      tree.forceActiveFocus()
      return true
    }
    return false
  }

  Keys.onEscapePressed: if (!back()) leave()
  onActiveFocusChanged: if (activeFocus && !detailOpen) tree.forceActiveFocus()
  // A work picked from elsewhere shows in the tree, once it is known.
  onPickedChanged: if (picked !== shown) unfold()
  onByWorkChanged: if (picked !== shown) unfold()

  // What waits for the rows to be made again. Timers, not Qt.callLater: they
  // go with the page when it is let go, never running on what is gone.
  Timer { id: filterLater; interval: 0; onTriggered: filterBox.forceActiveFocus() }
  Timer { id: treeLater; interval: 0; onTriggered: tree.forceActiveFocus() }
  // The row of the work `key` into view, the keyboard on it.
  Timer {
    id: reveal
    property string key
    interval: 0
    onTriggered: {
      const at = team.rowOf(key)
      if (at >= 0) {
        tree.currentIndex = at
        tree.positionViewAtIndex(at, ListView.Contain)
      }
    }
  }
  // The scroll and the keyboard's row back where they were.
  Timer {
    id: restore
    property string key
    interval: 0
    onTriggered: {
      tree.contentY = Math.max(tree.originY, Math.min(tree.keptY, tree.originY + tree.contentHeight - tree.height))
      tree.currentIndex = team.rowOf(key !== "" ? key : team.picked)
      key = ""
      tree.remaking = false
    }
  }

  // The tree, the detail over it once opened.
  ColumnLayout {
    anchors.fill: parent
    visible: !team.detailOpen
    spacing: Theme.space.block

    FilterBox {
      id: filterBox
      Layout.fillWidth: true
      placeholderText: "Search works, agents, stages…  /"
      onApplied: value => team.filter = value
      onLeave: tree.forceActiveFocus()
    }

    ChipStrip {
      Layout.fillWidth: true
      Layout.preferredHeight: implicitHeight
      Chip { text: "NEEDS YOU " + team.needsYou; checked: team.chip === "needs-you"; alert: team.needsYou > 0; accent: Theme.warning; onClicked: team.chip = checked ? "all" : "needs-you" }
      Chip { text: "WORKING " + team.working; checked: team.chip === "working"; onClicked: team.chip = checked ? "all" : "working" }
      Chip { text: "ALL " + team.flat.length + (team.flat.length === 1 ? " WORK" : " WORKS"); checked: team.chip === "all"; onClicked: team.chip = "all" }
    }

    ListView {
      id: tree
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: team.rows
      activeFocusOnTab: true
      keyNavigationEnabled: false
      currentIndex: -1
      Accessible.role: Accessible.Tree
      Accessible.name: "the works"
      readonly property real unit: Breakpoints.size(Window.width) === "narrow" ? Theme.space.section : Theme.size.gutter
      delegate: TreeNode {
        required property var modelData
        required property int index
        row: modelData
        width: tree.width
        unit: tree.unit
        picked: modelData.kind === "work" && team.picked === modelData.key
        highlighted: team.linked.includes(modelData.key)
        focused: tree.activeFocus && tree.currentIndex === index
        expanded: team.running[modelData.key] === true
        onChosen: {
          tree.currentIndex = index
          tree.forceActiveFocus()
          team.choose(modelData.key)
        }
        onToggled: {
          tree.currentIndex = index
          tree.forceActiveFocus()
          restore.key = modelData.key
          team.setOpen(modelData.key, !modelData.open)
        }
        onRequestPicked: id => team.requestPicked(modelData.kind === "work" ? modelData.key : "", id)
        onDetailWanted: team.open(modelData.key)
        onLogWanted: team.openLog(modelData.key)
      }

      // The rows are made again on each change: the scroll and the row the
      // keyboard is on stay where they were.
      property real keptY: 0
      property bool remaking: false
      onContentYChanged: if (!remaking) keptY = contentY
      onModelChanged: {
        remaking = true
        restore.restart()
      }
      // What an arrow does: a row to move to, or a work to open or close.
      function press(key) {
        const done = Tree.step(team.rows, currentIndex, key)
        if (done === null)
          return
        if (done.toggle !== undefined) {
          restore.key = done.toggle
          team.setOpen(done.toggle, done.open)
          return
        }
        currentIndex = done.at
        positionViewAtIndex(done.at, ListView.Contain)
        if (team.rows[done.at].kind === "work")
          team.picked = team.rows[done.at].key
      }
      onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0)
        currentIndex = team.rowOf(team.picked) >= 0 ? team.rowOf(team.picked) : team.rows.findIndex(row => row.kind !== "front")
      Keys.onUpPressed: press("up")
      Keys.onDownPressed: press("down")
      Keys.onRightPressed: press("right")
      Keys.onLeftPressed: press("left")
      // Enter shows a work's runs inside it; once shown, opens it in full.
      Keys.onReturnPressed: {
        const row = team.rows[currentIndex]
        if (!row || row.kind !== "work")
          return
        if (team.running[row.key] === true)
          team.open(row.key)
        else
          team.setRuns(row.key, true)
      }
      Keys.onPressed: event => {
        if (Typing.idle && event.text === "/") {
          team.focusFilter()
          event.accepted = true
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: team.flat.length === 0 || team.rows.every(row => row.kind === "front")
      text: team.progress === null ? "Reading the conversation."
        : team.flat.length === 0 ? "No work in this conversation yet." : "No work matches."
      color: Theme.dim
      font.pixelSize: Theme.type.body.size
      wrapMode: Text.Wrap
    }
  }

  // The work picked in full, over the whole page.
  NodeDetail {
    id: detail
    anchors.fill: parent
    visible: team.picked !== "" && team.detailOpen
    key: team.picked
    node: team.pickedNode
    trail: [{ text: "Conversation" }].concat(team.trailOf(team.picked).map(node => ({ text: node.title || node.agent })))
    closable: true
    onClosed: team.back()
    onCrumbChosen: index => {
      if (index === 0)
        team.back()
      else
        team.pick(team.trailOf(team.picked)[index - 1].work)
    }
    onPicked: key => team.open(key)
    onOpenLog: work => team.openLog(work)
    onDecide: (id, escalating) => team.decide(id, escalating)
  }
}
