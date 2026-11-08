pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/client/Team.js" as Team
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TeamView is the TEAM page: the conversation's agents as a tree (Team.rows,
// a TeamNode each) and the work picked in full (NodeDetail). The agent that
// talks with the person is the root when its works are other agents'; each
// work sits under the work that handed it down, every level deep, lines
// drawing who handed what to whom. A work with a work still open below it
// shows its works, and so does a root; the rest stay folded behind their
// chevron. Under an open work, the done ones fold into one line ("✓ 3
// sub-works done · 47 min · toolsmith, surgeon ×2"), those up next into
// another; once all are done, an agent's three or more do. Wide, the tree
// and the detail sit side by side; narrower, the detail opens as a page over
// the tree and BACK returns to the same row. Chips keep the works that need
// you or work, with the works above them; `/` filters by title, agent or
// stage. A ⇡/⇣ badge goes to the other end of its request, lights both and
// opens the request in the detail. ↑/↓ move, → opens or goes to the first
// row under, ← folds or goes to the parent, Enter opens the detail or its
// tabs, `[`/`]` change the tab, Esc goes detail, tree, back.
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
  readonly property var byWork: Team.index(flat)
  readonly property var pickedNode: byWork[picked] || null

  // Two panes wide, the detail as a page otherwise.
  readonly property bool wide: Breakpoints.size(Window.width) === "wide"
  property bool detailOpen: false

  // The tree's filters: "all", "needs-you" or "working", and the text.
  property string chip: "all"
  property string filter: ""
  // The works and folds opened (true) or closed (false) by hand.
  property var opened: ({})
  // The two works at the ends of the request whose badge was picked.
  property var linked: []

  readonly property int needsYou: progress ? progress.forYou.length : 0
  readonly property int working: flat.filter(node => node.state === "working").length + (progress && progress.front && progress.front.state === "working" ? 1 : 0)

  readonly property var rows: Team.rows(progress, opened, Team.kept(flat, chip, filter))
  function rowOf(key) { return rows.findIndex(row => row.key === key) }

  function setOpen(key, value) {
    const next = Object.assign({}, opened)
    next[key] = value
    opened = next
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
      opened = Team.reveal(progress, opened, picked)
    shown = picked
  }

  // A row chosen: picked, and narrower than wide, its detail opened.
  function choose(work) {
    pick(work)
    if (!wide)
      detailOpen = true
  }

  // Opens a work's detail: beside the tree wide, as a page otherwise.
  function open(work) {
    choose(work)
    if (wide)
      tabsLater.restart()
  }

  // A request's badge: both its ends lit, the other end picked, the request
  // open in the detail.
  function requestPicked(from, id) {
    const asker = flat.find(node => node.asks.some(ask => ask.id === id))
    const ask = asker ? asker.asks.find(each => each.id === id) : null
    const decider = ask && ask.toWork ? ask.toWork : ""
    linked = [asker ? asker.work : "", decider].filter(work => work !== "")
    const other = from === (asker ? asker.work : "") ? decider : asker ? asker.work : ""
    choose(other !== "" ? other : from)
    detail.show("requests")
  }

  // The request waiting on you nearest the work picked — its own, above it,
  // below it — else the newest.
  function nearestForYou() {
    const human = node => node.asks.filter(ask => ask.human).map(ask => ask.id)
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
    if (!wide)
      detailOpen = true
    detail.write(noting)
  }
  function showTab(name) {
    if (picked === "")
      return
    if (!wide)
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
  onWideChanged: if (wide) detailOpen = false
  // Wide, a work is always in the detail: the focus one at first.
  readonly property bool wantsPick: wide && picked === "" && progress !== null && progress.focus !== null
  onWantsPickChanged: if (wantsPick) firstPick.restart()
  // A work picked from elsewhere shows in the tree, once it is known.
  onPickedChanged: if (picked !== shown) unfold()
  onByWorkChanged: if (picked !== shown) unfold()

  // What waits for the rows to be made again. Timers, not Qt.callLater: they
  // go with the page when it is let go, never running on what is gone.
  Timer { id: firstPick; interval: 0; onTriggered: if (team.wantsPick) team.picked = team.progress.focus.work }
  Timer { id: tabsLater; interval: 0; onTriggered: detail.focusTabs() }
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

  // Wide: the tree beside the detail. Narrower: the tree, the detail over it.
  RowLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    ColumnLayout {
      Layout.fillHeight: true
      Layout.fillWidth: !team.wide
      Layout.preferredWidth: team.wide ? Math.max(440, team.width * 0.45) : -1
      Layout.minimumWidth: team.wide ? 380 : 0
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
        Accessible.name: "the team"
        readonly property real unit: Breakpoints.size(Window.width) === "narrow" ? Theme.space.block : Theme.size.gutter
        delegate: TeamNode {
          required property var modelData
          required property int index
          row: modelData
          width: tree.width
          unit: tree.unit
          picked: modelData.kind === "work" && team.picked === modelData.key
          highlighted: team.linked.includes(modelData.key)
          focused: tree.activeFocus && tree.currentIndex === index
          onChosen: {
            tree.currentIndex = index
            tree.forceActiveFocus()
            team.choose(modelData.key)
          }
          onToggled: {
            tree.currentIndex = index
            tree.forceActiveFocus()
            restore.key = modelData.key
            team.setOpen(modelData.key, modelData.kind === "fold" ? modelData.folded : !modelData.open)
          }
          onRequestPicked: id => team.requestPicked(modelData.kind === "work" ? modelData.key : "", id)
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
        // What an arrow does: a row to move to, the detail following a work,
        // or a work or fold to open or close.
        function press(key) {
          const done = Team.step(team.rows, currentIndex, key)
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
        Keys.onReturnPressed: {
          const row = team.rows[currentIndex]
          if (row && row.kind === "work")
            team.open(row.key)
          else if (row && row.kind === "fold") {
            restore.key = row.key
            team.setOpen(row.key, row.folded)
          }
        }
        Keys.onPressed: event => {
          if (!Typing.idle)
            return
          if (event.text === "/")
            team.focusFilter()
          else if (event.text === "[" || event.text === "]")
            detail.cycle(event.text === "]" ? 1 : -1)
          else
            return
          event.accepted = true
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

    Rectangle {
      visible: detailSlot.visible
      Layout.fillHeight: true
      implicitWidth: 1
      color: Theme.line
    }

    // Where the detail sits beside the tree.
    Item {
      id: detailSlot
      Layout.fillHeight: true
      Layout.fillWidth: team.wide
      visible: detail.visible && !detail.whole
    }
  }

  // The work picked in full: in its slot, or over the whole page.
  NodeDetail {
    id: detail
    readonly property bool whole: team.detailOpen
    x: whole ? 0 : detailSlot.x
    y: whole ? 0 : detailSlot.y
    width: whole ? team.width : detailSlot.width
    height: whole ? team.height : detailSlot.height
    visible: team.picked !== "" && (team.wide || team.detailOpen)
    key: team.picked
    node: team.pickedNode
    trail: (whole ? [{ text: "Conversation" }] : []).concat(team.trailOf(team.picked).map(node => ({ text: node.title || node.agent })))
    closable: team.detailOpen
    onClosed: team.back()
    onCrumbChosen: index => {
      const chain = team.trailOf(team.picked)
      if (whole && index === 0)
        team.back()
      else
        team.pick(chain[whole ? index - 1 : index].work)
    }
    onPicked: key => team.wide ? team.pick(key) : team.choose(key)
    onOpenLog: work => team.openLog(work)
    onDecide: (id, escalating) => team.decide(id, escalating)
  }
}
