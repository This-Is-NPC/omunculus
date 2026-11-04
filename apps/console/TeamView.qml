pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Requests.js" as Requests
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TeamView is the TEAM page: every work of the conversation, one row each,
// nested under the stage of the work that handed it down, siblings handed
// down in the same stage headed "N in parallel"; and the work picked in full
// (NodeDetail). Wide, the outline and the detail sit side by side; medium,
// the detail opens as a page over the outline and BACK returns to the same
// row; narrow, each level is a page — the work's card, then its sub-works —
// with a breadcrumb, a row going one level down. From 900 px the outline may
// give way to the map (AgentsView), the detail still beside it. Chips keep
// the works that need you or work, with the works above them; `/` filters
// by title, agent or stage. A ⇡/⇣ badge lights both ends of its request,
// brings the other into view and opens the request in the detail. ↑/↓ move,
// →/← unfold and fold (on a folded row, go to its parent), Enter opens the
// detail or its tabs, `[`/`]` change the tab, Esc goes detail, outline,
// back.
FocusScope {
  id: team

  // The work picked, or "" for none.
  property string picked: ""
  // "outline" or "map"; the map shows only where there is room for it.
  property string shownAs: "outline"
  signal leave()
  signal openLog(string work)

  readonly property var progress: Omunculus.progress || null
  readonly property var roots: progress ? progress.roots : []
  readonly property var flat: progress ? progress.flat : []
  readonly property var byWork: {
    const found = {}
    for (const node of flat)
      found[node.work] = node
    return found
  }
  readonly property var pickedNode: byWork[picked] || null

  // The chrome decides by the window: two panes wide, a page over the
  // outline medium, a page per level narrow; the map from 900 px.
  readonly property string size: Breakpoints.size(Window.width)
  readonly property bool mapAllowed: Window.width >= 900
  readonly property bool mapShown: shownAs === "map" && mapAllowed
  readonly property real indentStep: Breakpoints.indent(Window.width)
  // Deeper rows stay at this indent, so a deep tree keeps its width.
  readonly property int deepest: 6
  // Medium and narrow: the detail is a page of its own.
  property bool detailOpen: false
  // Narrow: the work whose level shows, "" for the conversation's.
  property string level: ""

  // The outline's filters: "all", "needs-you" or "working", and the text.
  property string chip: "all"
  property string filter: ""
  // The rows unfolded (true) or folded (false) by hand, by key.
  property var opened: ({})
  // The two works at the ends of the request whose badge was picked.
  property var linked: []

  readonly property int needsYou: flat.filter(node => node.state === "needs-you").length
  readonly property int working: flat.filter(node => node.state === "working").length

  function closed(node) { return node.state === "done" || node.state === "cancelled" }
  function kidsOf(node) { return node.groups.reduce((all, group) => all.concat(group.nodes), []) }

  // The works the filters keep: those that match, and every work above one.
  readonly property var kept: {
    const words = filter.toLowerCase().split(/\s+/).filter(word => word)
    if (chip === "all" && words.length === 0)
      return null
    const keep = {}
    for (const node of flat) {
      const text = [node.title, node.agent].concat((node.steps || []).map(step => step.name)).join(" ").toLowerCase()
      const state = chip === "all" || node.state === chip
      if (state && words.every(word => text.includes(word)))
        for (let at = node; at && !keep[at.work]; at = byWork[at.parent])
          keep[at.work] = true
    }
    return keep
  }
  function keeps(node) { return kept === null || !!kept[node.work] }

  function isFolded(key, unless) { return opened[key] !== undefined ? !opened[key] : unless }
  function setOpen(key, value) {
    const next = Object.assign({}, opened)
    next[key] = value
    opened = next
  }

  // The outline's rows, in order: works, the stage and parallel headings
  // between them, level headings in a long list, and the works done earlier.
  readonly property var rows: {
    const list = []
    const filtering = kept !== null
    const walk = (node, indent) => {
      if (!keeps(node))
        return
      const kids = kidsOf(node).filter(keeps)
      const folded = kids.length > 0 && isFolded(node.work, closed(node) || node.state === "up-next")
      list.push({ kind: "work", key: node.work, node: node, indent: indent, folds: kids.length > 0, folded: folded && !filtering })
      if (folded && !filtering)
        return
      node.groups.forEach((group, at) => {
        const shown = group.nodes.filter(keeps)
        if (shown.length === 0)
          return
        let inner = indent + 1
        if (group.step) {
          const key = "stage:" + node.work + ":" + at
          const done = shown.every(closed)
          const stageFolded = !filtering && isFolded(key, done)
          list.push({ kind: "stage", key: key, indent: indent + 1, folds: true, folded: stageFolded,
            text: group.step + " stage" + (stageFolded && done ? " · " + shown.length + (shown.length === 1 ? " sub-work" : " sub-works") + " done" : "") })
          if (stageFolded)
            return
          inner = indent + 2
        }
        if (group.parallel) {
          const key = "group:" + node.work + ":" + at
          const counts = group.counts || {}
          const groupFolded = !filtering && isFolded(key, false)
          list.push({ kind: "group", key: key, indent: inner, folds: true, folded: groupFolded,
            text: group.nodes.length + " in parallel" + (counts.working ? " · " + counts.working + " working" : "")
              + (counts.waiting ? " · " + counts.waiting + " waiting" : "") + (counts.done ? " · " + counts.done + " done" : "") })
          if (groupFolded)
            return
          inner++
        }
        shown.forEach(kid => walk(kid, inner))
      })
    }
    const open = roots.filter(node => !closed(node))
    const earlier = open.length > 0 ? roots.filter(closed).filter(keeps) : []
    for (const root of open.length > 0 ? open : roots)
      walk(root, 0)
    if (earlier.length > 0) {
      const folded = !filtering && isFolded("earlier", true)
      list.push({ kind: "earlier", key: "earlier", indent: 0, folds: true, folded: folded, text: earlier.length + " done earlier" })
      if (!folded)
        earlier.forEach(root => walk(root, 0))
    }
    // In a long list, a thin heading where the level changes.
    if (list.filter(row => row.kind === "work").length <= 12)
      return list
    const perLevel = {}
    for (const node of flat)
      perLevel[node.level] = (perLevel[node.level] || 0) + 1
    const headed = []
    let last = -1
    for (const row of list) {
      if (row.kind === "work" && row.node.level !== last) {
        last = row.node.level
        headed.push({ kind: "level", key: "level:" + headed.length, indent: row.indent, folds: false, folded: false,
          text: "Level " + last + " · " + perLevel[last] + (perLevel[last] === 1 ? " work" : " works") })
      }
      headed.push(row)
    }
    return headed
  }
  function rowOf(key) { return rows.findIndex(row => row.key === key) }

  // The way down to a work, outermost first.
  function trailOf(work) {
    const chain = []
    for (let at = byWork[work]; at; at = byWork[at.parent])
      chain.unshift(at)
    return chain
  }

  // Picks a work: its row comes into view, its folded ancestors open.
  function pick(work) {
    picked = work
    let next = null
    for (let at = byWork[byWork[work] ? byWork[work].parent : ""]; at; at = byWork[at.parent]) {
      if (isFolded(at.work, closed(at) || at.state === "up-next")) {
        next = next || Object.assign({}, opened)
        next[at.work] = true
      }
    }
    if (next)
      opened = next
    Qt.callLater(() => {
      const at = rowOf(work)
      if (at >= 0) {
        outline.currentIndex = at
        outline.positionViewAtIndex(at, ListView.Contain)
      }
    })
  }

  // Opens a work's detail: beside the outline wide, as a page otherwise.
  function open(work) {
    pick(work)
    if (size === "narrow") {
      const node = byWork[work]
      level = node ? node.parent : ""
    }
    if (size !== "wide")
      detailOpen = true
    else
      Qt.callLater(() => detail.focusTabs())
  }

  // A request's badge: both its ends lit, the other end into view, the
  // request open in the detail of the row whose badge it was.
  function requestPicked(from, id) {
    const asker = flat.find(node => (node.asks || []).some(ask => ask.id === id))
    const ask = asker ? asker.asks.find(each => each.id === id) : null
    const decider = ask && ask.toWork ? ask.toWork : ""
    linked = [asker ? asker.work : "", decider].filter(work => work !== "")
    const other = from === (asker ? asker.work : "") ? decider : asker ? asker.work : ""
    if (size === "narrow" && other !== "") {
      open(other)
    } else {
      if (other !== "")
        pick(other)
      pick(from)
      if (size !== "wide")
        detailOpen = true
    }
    detail.show("requests")
  }

  // The request waiting on you nearest the work picked — its own, above it,
  // below it — else the newest.
  function nearestForYou() {
    const human = node => (node.asks || []).filter(ask => ask.human).map(ask => ask.id)
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
    if (size !== "wide")
      detailOpen = true
    detail.write(noting)
  }
  function showTab(name) {
    if (picked === "")
      return
    if (size !== "wide")
      detailOpen = true
    detail.show(name)
  }
  function fit() { if (mapLoader.item) mapLoader.item.fit() }
  function focusFilter() {
    if (size !== "narrow") {
      shownAs = "outline"
      wideFilters.focusBox()
      return
    }
    detailOpen = false
    level = ""
    Qt.callLater(() => narrowFilters.focusBox())
  }

  // Lets go of one thing: the detail page, then a level; false when there
  // is nothing more to let go of.
  function back() {
    if (detailOpen) {
      detailOpen = false
      Qt.callLater(() => size === "narrow" ? levelList.forceActiveFocus() : outline.forceActiveFocus())
      return true
    }
    if (size === "narrow" && level !== "") {
      const node = byWork[level]
      level = node ? node.parent : ""
      return true
    }
    if (detail.activeFocus) {
      outline.forceActiveFocus()
      return true
    }
    return false
  }

  Keys.onEscapePressed: if (!back()) leave()
  onActiveFocusChanged: if (activeFocus && !detailOpen) (size === "narrow" ? levelList : outline).forceActiveFocus()
  onSizeChanged: if (size === "wide") detailOpen = false
  // Wide, a work is always in the detail: the focus one at first.
  readonly property bool wantsPick: size === "wide" && picked === "" && progress !== null && progress.focus !== null
  onWantsPickChanged: if (wantsPick) picked = progress.focus.work

  // A row of the outline, as ListView shows it.
  component OutlineRow: Item {
    id: line
    required property var row
    required property int index
    readonly property bool current: line.row.kind === "work" && team.picked === line.row.key

    width: outline.width
    height: line.row.kind === "work" ? node.implicitHeight + 6 : 26

    // The row picked: a wash over its whole width.
    Rectangle {
      anchors.fill: parent
      visible: line.current || (line.row.kind !== "work" && outline.activeFocus && outline.currentIndex === line.index)
      color: Qt.alpha(Theme.primary, 0.07)
    }

    // A heading: a stage, a parallel group, a level, the works done earlier.
    RowLayout {
      visible: line.row.kind !== "work"
      anchors { fill: parent; leftMargin: 4 + Math.min(line.row.indent, team.deepest) * team.indentStep; rightMargin: 4 }
      spacing: 6
      Icon {
        visible: line.row.folds
        name: line.row.folded ? "chevron-right" : "chevron-down"
        size: 12
        color: Theme.dim
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: line.row.text || ""
        color: Theme.dim
        font.pixelSize: 11
        font.letterSpacing: line.row.kind === "level" ? 1 : 0
        elide: Text.ElideRight
      }
      TapHandler {
        enabled: line.row.folds
        onTapped: {
          outline.currentIndex = line.index
          outline.forceActiveFocus()
          team.setOpen(line.row.key, line.row.folded)
        }
      }
    }

    // A work.
    Loader {
      id: node
      active: line.row.kind === "work"
      x: Math.min(line.row.indent, team.deepest) * team.indentStep
      y: 3
      width: Math.max(0, parent.width - x)
      sourceComponent: ProgressNode {
        node: line.row.node
        mode: "full"
        active: line.current
        highlighted: team.linked.includes(line.row.key)
        folds: line.row.folds
        folded: line.row.folded
        onToggled: {
          outline.currentIndex = line.index
          outline.forceActiveFocus()
          team.picked = line.row.key
          if (team.size !== "wide")
            team.open(line.row.key)
        }
        onFoldToggled: team.setOpen(line.row.key, line.row.folded)
        onRequestPicked: id => team.requestPicked(line.row.key, id)
        onOpenThread: work => { team.open(work); detail.show("thread") }
        onOpenLog: work => team.openLog(work)
        onOpenMap: work => { team.shownAs = "map"; team.pick(work) }
      }
    }
  }

  // The filters over the outline.
  component Filters: ColumnLayout {
    function focusBox() { box.forceActiveFocus() }
    spacing: 6
    FilterBox {
      id: box
      Layout.fillWidth: true
      placeholderText: "filter works, agents, stages"
      onApplied: value => team.filter = value
      onLeave: (team.size === "narrow" ? levelList : outline).forceActiveFocus()
    }
    Flow {
      Layout.fillWidth: true
      spacing: 6
      Chip { text: "NEEDS YOU " + team.needsYou; checked: team.chip === "needs-you"; accent: Theme.warning; onClicked: team.chip = checked ? "all" : "needs-you" }
      Chip { text: "WORKING " + team.working; checked: team.chip === "working"; onClicked: team.chip = checked ? "all" : "working" }
      Chip { text: "ALL " + team.flat.length; checked: team.chip === "all"; onClicked: team.chip = "all" }
    }
  }

  // Wide and medium: the outline, or the map, and the detail.
  RowLayout {
    anchors.fill: parent
    visible: team.size !== "narrow"
    spacing: 14

    ColumnLayout {
      Layout.fillHeight: true
      Layout.fillWidth: team.size !== "wide" || team.mapShown
      Layout.preferredWidth: team.size === "wide" && !team.mapShown ? 440 : -1
      Layout.minimumWidth: team.size === "wide" && !team.mapShown ? 380 : 0
      visible: !team.detailOpen
      spacing: 8

      Filters {
        id: wideFilters
        Layout.fillWidth: true
        visible: !team.mapShown
      }

      ListView {
        id: outline
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !team.mapShown
        clip: true
        spacing: 4
        boundsBehavior: Flickable.StopAtBounds
        model: team.rows
        activeFocusOnTab: true
        keyNavigationEnabled: false
        currentIndex: -1
        delegate: OutlineRow {
          required property var modelData
          row: modelData
        }
        // The rows are made again on each change: the scroll and the row the
        // keyboard is on stay where they were.
        property real keptY: 0
        property bool remaking: false
        onContentYChanged: if (!remaking) keptY = contentY
        onModelChanged: {
          remaking = true
          Qt.callLater(() => {
            outline.contentY = Math.max(outline.originY, Math.min(outline.keptY, outline.originY + outline.contentHeight - outline.height))
            outline.currentIndex = team.rowOf(team.picked)
            outline.remaking = false
          })
        }
        // Moves the keyboard `by` rows; the detail follows a work.
        function step(by) {
          currentIndex = Math.max(0, Math.min(count - 1, currentIndex + by))
          positionViewAtIndex(currentIndex, ListView.Contain)
          const row = team.rows[currentIndex]
          if (row && row.kind === "work")
            team.picked = row.key
        }
        onActiveFocusChanged: if (activeFocus && currentIndex < 0) currentIndex = Math.max(0, team.rowOf(team.picked))
        Keys.onUpPressed: step(-1)
        Keys.onDownPressed: step(1)
        Keys.onRightPressed: {
          const row = team.rows[currentIndex]
          if (row && row.folds && row.folded)
            team.setOpen(row.key, true)
        }
        Keys.onLeftPressed: {
          const row = team.rows[currentIndex]
          if (!row)
            return
          if (row.folds && !row.folded) {
            team.setOpen(row.key, false)
          } else if (row.kind === "work" && row.node.parent !== "") {
            team.pick(row.node.parent)
          }
        }
        Keys.onReturnPressed: {
          const row = team.rows[currentIndex]
          if (row && row.kind === "work")
            team.open(row.key)
          else if (row && row.folds)
            team.setOpen(row.key, row.folded)
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
        FocusRing { shown: outline.activeFocus && outline.currentIndex < 0 }
      }

      Loader {
        id: mapLoader
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: team.mapShown
        active: team.mapShown
        sourceComponent: AgentsView {
          picked: team.picked
          highlighted: team.linked
          onChosen: work => {
            if (work === "")
              return
            team.picked = work
            if (team.size !== "wide")
              team.detailOpen = true
          }
          onRequestPicked: id => {
            const asker = team.flat.find(node => (node.asks || []).some(ask => ask.id === id))
            team.requestPicked(asker ? asker.work : team.picked, id)
          }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: team.flat.length === 0 && !team.mapShown
        text: team.progress ? "No work in this conversation yet." : "Reading the conversation."
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

    Rectangle {
      visible: team.size === "wide" || (team.mapShown && team.picked !== "")
      Layout.fillHeight: true
      implicitWidth: 1
      color: Theme.line
    }

    // Where the detail sits beside the outline or the map, or over it.
    Item {
      id: detailSlot
      Layout.fillHeight: true
      Layout.fillWidth: team.size === "wide" && !team.mapShown || team.detailOpen
      Layout.preferredWidth: team.mapShown && !team.detailOpen ? (team.size === "wide" ? 420 : team.width * 0.45) : -1
      visible: detail.visible
    }
  }

  // Narrow: a page per level, or the detail of a work.
  ColumnLayout {
    anchors.fill: parent
    visible: team.size === "narrow"
    spacing: 8

    Breadcrumb {
      Layout.fillWidth: true
      visible: !team.detailOpen
      trail: [{ text: "Conversation" }].concat(team.trailOf(team.level).map(node => ({ text: node.title })))
      onChosen: index => team.level = index === 0 ? "" : team.trailOf(team.level)[index - 1].work
    }
    Filters {
      id: narrowFilters
      Layout.fillWidth: true
      visible: !team.detailOpen && team.level === ""
    }

    ListView {
      id: levelList
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !team.detailOpen
      clip: true
      spacing: 6
      boundsBehavior: Flickable.StopAtBounds
      activeFocusOnTab: true
      keyNavigationEnabled: true
      // The level's own card first, then its sub-works, each group headed.
      model: {
        const here = team.byWork[team.level] || null
        const list = here ? [{ kind: "self", node: here }] : []
        if (here) {
          here.groups.forEach(group => {
            const shown = group.nodes.filter(team.keeps)
            if (shown.length === 0)
              return
            const counts = group.counts || {}
            list.push({ kind: "head", text: "Sub-works" + (group.step ? " · " + group.step + " stage" : "")
              + (group.parallel ? " · " + group.nodes.length + " in parallel" + (counts.working ? " · " + counts.working + " working" : "") + (counts.done ? " · " + counts.done + " done" : "") : "") })
            shown.forEach(node => list.push({ kind: "work", node: node }))
          })
        } else {
          team.roots.filter(team.keeps).forEach(node => list.push({ kind: "work", node: node }))
        }
        return list
      }
      Keys.onReturnPressed: if (currentItem) currentItem.enter()
      Keys.onPressed: event => {
        if (Typing.idle && event.text === "/") {
          team.focusFilter()
          event.accepted = true
        }
      }
      delegate: Item {
        id: entry
        required property var modelData
        required property int index
        readonly property bool drills: modelData.kind === "work" && team.kidsOf(modelData.node).length > 0
        width: levelList.width
        height: modelData.kind === "head" ? 26 : card.implicitHeight

        // A work row goes a level down, or to its detail when nothing is below.
        function enter() {
          if (modelData.kind === "head")
            return
          if (drills)
            team.level = modelData.node.work
          else
            team.open(modelData.node.work)
        }

        Label {
          visible: entry.modelData.kind === "head"
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 4 }
          text: entry.modelData.text || ""
          color: Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
        RowLayout {
          id: card
          visible: entry.modelData.kind !== "head"
          width: parent.width
          spacing: 4
          Loader {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            active: entry.modelData.kind !== "head"
            sourceComponent: ProgressNode {
              node: entry.modelData.node
              mode: "full"
              active: levelList.activeFocus && levelList.currentIndex === entry.index
              highlighted: team.linked.includes(entry.modelData.node.work)
              onToggled: {
                levelList.currentIndex = entry.index
                if (entry.modelData.kind === "self")
                  team.open(entry.modelData.node.work)
                else
                  entry.enter()
              }
              onRequestPicked: id => team.requestPicked(entry.modelData.node.work, id)
              onOpenThread: work => { team.open(work); detail.show("thread") }
              onOpenLog: work => team.openLog(work)
              onOpenMap: work => team.open(work)
            }
          }
          Icon {
            visible: entry.drills
            Layout.alignment: Qt.AlignVCenter
            name: "chevron-right"
            size: 12
            color: Theme.dim
          }
        }
      }

      Label {
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        visible: levelList.count === 0
        text: team.progress ? "No work in this conversation yet." : "Reading the conversation."
        color: Theme.dim
        font.pixelSize: 12
        wrapMode: Text.Wrap
      }
    }

  }

  // The work picked in full: in its slot, or over the whole page when narrow.
  NodeDetail {
    id: detail
    readonly property bool whole: team.size === "narrow"
    x: whole ? 0 : detailSlot.x
    y: whole ? 0 : detailSlot.y
    width: whole ? team.width : detailSlot.width
    height: whole ? team.height : detailSlot.height
    visible: team.picked !== "" && (team.size === "narrow" ? team.detailOpen : team.size === "wide" || team.detailOpen || team.mapShown)
    key: team.picked
    node: team.pickedNode
    trail: (whole ? [{ text: "Conversation" }] : []).concat(team.trailOf(team.picked).map(node => ({ text: node.title })))
    closable: team.detailOpen
    mappable: team.mapAllowed && !team.mapShown
    onClosed: team.back()
    onCrumbChosen: index => {
      const chain = team.trailOf(team.picked)
      if (!whole) {
        team.pick(chain[index].work)
        return
      }
      team.detailOpen = false
      team.level = index === 0 ? "" : chain[index - 1].work
    }
    onPicked: key => team.size === "narrow" ? team.open(key) : team.pick(key)
    onOpenLog: work => team.openLog(work)
    onOpenMap: work => {
      team.detailOpen = false
      team.shownAs = "map"
      team.pick(work)
    }
  }
}
