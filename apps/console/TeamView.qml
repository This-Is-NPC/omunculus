pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Progress.js" as Progress
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// TeamView is the TEAM page: the works of the conversation a level at a
// time, under a breadcrumb once it has gone down into a work, and the work
// picked in full (NodeDetail). At the conversation's level the agent that
// talks with the person is the head of the team ("sales · talks with you ·
// 2 agents", with what it asks), the works nested under it, a block in per
// level. A level is a work's own row, then the works it handed down, a row
// each, under a rule (at the rows' indent) for the stage that handed them
// down ("STAGE DESIGN · 2 IN PARALLEL"); a work at work, on the way to it or
// with a question for you below shows its open works under it, a level in;
// those done or cancelled fold into one rule per stage, "✓ 2 sub-works done ·
// 18 min", unless a question waiting on you climbed from there. A row's tool
// goes down to the works below it; the conversation's level is its root
// works, the one work's own when there is a single one, those done before
// an open one folded under "N done earlier". Wide, the outline and the
// detail sit side by side; narrower, the detail opens as a page over the
// outline and BACK returns to the same row. From 900 px OUTLINE and MAP, at
// the right of the filters, switch the outline for the map (AgentsView), the
// detail still beside it. Chips keep the works that need you or work, with
// the works above them; `/` filters by title, agent or stage. A ⇡/⇣ badge
// goes to the other end of its request, lights both and opens the request
// in the detail. ↑/↓ move, → goes down a level or unfolds, ← folds or goes up
// one, Enter opens the detail or its tabs, `[`/`]` change the tab, Esc goes
// detail, outline, a level up, back.
FocusScope {
  id: team

  // The work picked, or "" for none.
  property string picked: ""
  // "outline" or "map"; the map shows only where there is room for it.
  property string shownAs: "outline"
  signal leave()
  signal openLog(string work)
  // A request's decision, over the page: to answer it or, `escalating`, to
  // raise it to whoever decides above you.
  signal decide(string id, bool escalating)

  readonly property var progress: Omunculus.progress
  readonly property var roots: progress ? progress.roots : []
  readonly property var flat: progress ? progress.flat : []
  readonly property var byWork: {
    const found = {}
    for (const node of flat)
      found[node.work] = node
    return found
  }
  readonly property var pickedNode: byWork[picked] || null

  // The chrome decides by the window: two panes wide, the detail as a page
  // otherwise; the map from 900 px.
  readonly property bool wide: Breakpoints.size(Window.width) === "wide"
  readonly property bool mapAllowed: Window.width >= 900
  readonly property bool mapShown: shownAs === "map" && mapAllowed
  // Narrower than wide: the detail is a page of its own.
  property bool detailOpen: false
  // The work whose level shows, "" for the conversation's, which is the one
  // root work's own when there is only one.
  property string level: ""
  readonly property string here: byWork[level] ? level : roots.length === 1 ? roots[0].work : ""

  // The outline's filters: "all", "needs-you" or "working", and the text.
  property string chip: "all"
  property string filter: ""
  // The folds unfolded (true) or folded (false) by hand.
  property var opened: ({})
  // The two works at the ends of the request whose badge was picked.
  property var linked: []

  // The agent that talks with the person, at the conversation's level.
  readonly property var front: progress && progress.front && (here === "" || byWork[here].parent === "") ? progress.front : null
  readonly property int needsYou: progress ? progress.forYou.length : 0
  readonly property int working: flat.filter(node => node.state === "working").length + (front !== null && front.state === "working" ? 1 : 0)

  function closed(node) { return Progress.closed(node.state) }
  // The fold the done and cancelled works of a parent's group `at` go in.
  function doneKey(parent, at) { return "done:" + parent.work + ":" + at }

  // The works the filters keep: those that match, and every work above one.
  readonly property var kept: {
    const words = filter.toLowerCase().split(/\s+/).filter(word => word)
    if (chip === "all" && words.length === 0)
      return null
    const keep = {}
    for (const node of flat) {
      const text = [node.title, node.agent].concat(node.steps.map(step => step.name)).join(" ").toLowerCase()
      const state = chip === "all" || node.state === chip
      if (state && words.every(word => text.includes(word)))
        for (let at = node; at && !keep[at.work]; at = byWork[at.parent])
          keep[at.work] = true
    }
    return keep
  }
  function keeps(node) { return kept === null || !!kept[node.work] }

  function setOpen(key, value) {
    const next = Object.assign({}, opened)
    next[key] = value
    opened = next
  }

  // The outline's rows, in order: the level's own work, then each group of
  // the works it handed down under its rule, those done folded after them.
  readonly property var rows: {
    const list = []
    // A filter shows every row it keeps.
    const isFolded = (key, unless) => kept !== null ? false : opened[key] !== undefined ? !opened[key] : unless
    const head = front !== null ? 1 : 0
    const workRow = (node, self, depth) => ({ kind: "work", key: node.work, node: node, depth: depth, drills: !self && Progress.kidsOf(node).length > 0 })
    // A work, then the open works under it that are at work or on the way to
    // it, each one level deeper.
    const place = (node, depth) => {
      list.push(workRow(node, false, depth))
      Progress.opened(node, progress.path).filter(keeps).forEach(kid => place(kid, depth + 1))
    }
    const node = byWork[here] || null
    if (front !== null)
      list.push({ kind: "front", key: "front", front: front })
    if (node === null) {
      const open = roots.filter(each => !closed(each))
      const earlier = open.length > 0 ? roots.filter(closed).filter(keeps) : []
      for (const root of (open.length > 0 ? open : roots).filter(keeps))
        place(root, head)
      if (earlier.length > 0) {
        const folded = isFolded("earlier", true)
        list.push({ kind: "done", key: "earlier", depth: head, folded: folded, text: earlier.length + " done earlier" })
        if (!folded)
          earlier.forEach(root => list.push(workRow(root, false, head)))
      }
      return list
    }
    list.push(workRow(node, true, head))
    node.groups.forEach((group, at) => {
      const shown = group.nodes.filter(keeps)
      if (shown.length === 0)
        return
      const going = shown.filter(kid => !closed(kid))
      const finished = shown.filter(closed)
      const title = [group.step ? "stage " + group.step : "", group.parallel && going.length > 1 ? Progress.together(group) : ""]
        .filter(part => part).join(" · ")
      list.push({ kind: "rule", key: "rule:" + at, depth: head + 1, text: title || "sub-works" })
      going.forEach(kid => place(kid, head + 1))
      if (finished.length > 0) {
        const key = doneKey(node, at)
        const folded = isFolded(key, !finished.some(kid => kid.below !== ""))
        list.push({ kind: "done", key: key, depth: head + 1, folded: folded, text: Progress.finished(finished) })
        if (!folded)
          finished.forEach(kid => list.push(workRow(kid, false, head + 1)))
      }
    })
    return list
  }
  function rowOf(key) { return rows.findIndex(row => row.key === key) }

  // The way down to a work, outermost first.
  function trailOf(work) {
    const chain = []
    for (let at = byWork[work]; at; at = byWork[at.parent])
      chain.unshift(at)
    return chain
  }

  // Picks a work: its level shows, the fold it is in opens, its row comes
  // into view.
  function pick(work) {
    picked = work
    const node = byWork[work]
    if (node && work !== here) {
      const parent = byWork[node.parent] || null
      level = parent ? parent.work : ""
      if (parent && closed(node))
        setOpen(doneKey(parent, parent.groups.findIndex(group => group.nodes.includes(node))), true)
      else if (!parent && closed(node) && roots.some(root => !closed(root)))
        setOpen("earlier", true)
    }
    reveal.key = work
    reveal.restart()
  }

  // A row chosen: picked, and narrower than wide, its detail opened.
  function choose(work) {
    pick(work)
    if (!wide)
      detailOpen = true
  }

  // Opens a work's detail: beside the outline wide, as a page otherwise.
  function open(work) {
    choose(work)
    if (wide)
      tabsLater.restart()
  }

  // Goes down to the works a work handed down.
  function drill(work) {
    level = work
    picked = work
    reveal.key = work
    reveal.restart()
  }

  // Goes up a level, the work it was on picked; false at the top.
  function up() {
    const node = byWork[here]
    if (!node || (node.parent === "" && roots.length === 1))
      return false
    pick(node.work)
    level = node.parent
    return true
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
  function fit() { if (mapLoader.item) mapLoader.item.fit() }
  function focusFilter() {
    shownAs = "outline"
    detailOpen = false
    filterLater.restart()
  }

  // Lets go of one thing: the detail page, the keyboard in the detail, then
  // a level; false when there is nothing more to let go of.
  function back() {
    if (detailOpen) {
      detailOpen = false
      outlineLater.restart()
      return true
    }
    if (detail.activeFocus) {
      outline.forceActiveFocus()
      return true
    }
    return !mapShown && up()
  }

  Keys.onEscapePressed: if (!back()) leave()
  onActiveFocusChanged: if (activeFocus && !detailOpen) outline.forceActiveFocus()
  onWideChanged: if (wide) detailOpen = false
  // Wide, a work is always in the detail: the focus one at first.
  readonly property bool wantsPick: wide && picked === "" && progress !== null && progress.focus !== null
  onWantsPickChanged: if (wantsPick) firstPick.restart()

  // What waits for the rows to be made again. Timers, not Qt.callLater: they
  // go with the page when it is let go, never running on what is gone.
  Timer { id: firstPick; interval: 0; onTriggered: if (team.wantsPick) team.picked = team.progress.focus.work }
  Timer { id: tabsLater; interval: 0; onTriggered: detail.focusTabs() }
  Timer { id: filterLater; interval: 0; onTriggered: filterBox.forceActiveFocus() }
  Timer { id: outlineLater; interval: 0; onTriggered: outline.forceActiveFocus() }
  // The row of the work `key` into view, the keyboard on it.
  Timer {
    id: reveal
    property string key
    interval: 0
    onTriggered: {
      const at = team.rowOf(key)
      if (at >= 0) {
        outline.currentIndex = at
        outline.positionViewAtIndex(at, ListView.Contain)
      }
    }
  }
  // The scroll and the keyboard's row back where they were.
  Timer {
    id: restore
    interval: 0
    onTriggered: {
      outline.contentY = Math.max(outline.originY, Math.min(outline.keptY, outline.originY + outline.contentHeight - outline.height))
      outline.currentIndex = team.rowOf(team.picked)
      outline.remaking = false
    }
  }

  // Wide: the outline, or the map, beside the detail. Narrower: the outline
  // or the map, the detail over them, or beside the map.
  RowLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    ColumnLayout {
      Layout.fillHeight: true
      Layout.fillWidth: !team.wide || team.mapShown
      Layout.preferredWidth: team.wide && !team.mapShown ? 440 : -1
      Layout.minimumWidth: team.wide && !team.mapShown ? 380 : 0
      visible: !team.detailOpen
      spacing: Theme.space.block

      // The search line, and the view at its right end.
      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.gap
        FilterBox {
          id: filterBox
          Layout.fillWidth: true
          visible: !team.mapShown
          placeholderText: "Search works, agents, stages…  /"
          onApplied: value => team.filter = value
          onLeave: outline.forceActiveFocus()
        }
        Item { Layout.fillWidth: true; visible: team.mapShown }
        // One joined control: its borders overlap.
        Row {
          visible: team.mapAllowed
          spacing: -1
          Chip { text: "OUTLINE"; icon: "list"; checked: !team.mapShown; tip: "the works as an outline"; onClicked: team.shownAs = "outline" }
          Chip { text: "MAP"; icon: "map"; checked: team.mapShown; tip: "the works as a map, one card each"; onClicked: team.shownAs = "map" }
        }
      }

      ChipStrip {
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
        visible: !team.mapShown
        Chip { text: "NEEDS YOU " + team.needsYou; checked: team.chip === "needs-you"; alert: team.needsYou > 0; accent: Theme.warning; onClicked: team.chip = checked ? "all" : "needs-you" }
        Chip { text: "WORKING " + team.working; checked: team.chip === "working"; onClicked: team.chip = checked ? "all" : "working" }
        Chip { text: "ALL " + team.flat.length + (team.flat.length === 1 ? " WORK" : " WORKS"); checked: team.chip === "all"; onClicked: team.chip = "all" }
      }

      Breadcrumb {
        Layout.fillWidth: true
        visible: !team.mapShown && team.level !== "" && team.here !== ""
        trail: [{ text: "Conversation" }].concat(team.trailOf(team.here).map(node => ({ text: node.title || node.agent })))
        onChosen: index => {
          const chain = team.trailOf(team.here)
          if (index === 0)
            team.level = ""
          else
            team.drill(chain[index - 1].work)
        }
      }

      ListView {
        id: outline
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !team.mapShown
        clip: true
        spacing: Theme.space.row
        boundsBehavior: Flickable.StopAtBounds
        model: team.rows
        activeFocusOnTab: true
        keyNavigationEnabled: false
        currentIndex: -1
        delegate: Item {
          id: line
          required property var modelData
          required property int index
          readonly property bool focused: outline.activeFocus && outline.currentIndex === index
          // A level in, what it groups sits one block further.
          readonly property real indent: (modelData.depth || 0) * Theme.space.block

          // Where a level begins, a gap sets its first card apart from the one above.
          readonly property real lead: modelData.kind === "work" && index > 0 && (modelData.depth || 0) > (team.rows[index - 1].depth || 0) ? Theme.space.gap : 0

          width: outline.width
          height: modelData.kind === "work" ? (node.item ? node.item.implicitHeight : 0) + lead
            : modelData.kind === "front" ? Theme.size.strip : Theme.size.rule

          // A stage, a parallel group.
          Kicker {
            visible: line.modelData.kind === "rule"
            x: line.indent
            width: parent.width - x
            height: parent.height
            text: line.modelData.text || ""
          }

          // The done and cancelled works of a place, or the works done
          // earlier, folded or not.
          Item {
            visible: line.modelData.kind === "done"
            anchors.fill: parent
            RowLayout {
              anchors { left: parent.left; leftMargin: line.indent; right: parent.right; bottom: parent.bottom; bottomMargin: Theme.space.line }
              spacing: Theme.space.gap
              Label {
                text: "✓"
                color: Theme.success
                font.pixelSize: Theme.type.section.size
              }
              Label {
                Layout.maximumWidth: implicitWidth
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: (line.modelData.text || "").toUpperCase()
                color: Theme.dim
                font.pixelSize: Theme.type.section.size
                font.letterSpacing: Theme.type.section.tracking
                elide: Text.ElideRight
              }
              Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }
              Icon {
                name: line.modelData.folded ? "chevron-right" : "chevron-down"
                size: 12
                color: foldHover.hovered || line.focused ? Theme.primary : Theme.dim
              }
            }
            HoverHandler { id: foldHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              onTapped: {
                outline.currentIndex = line.index
                outline.forceActiveFocus()
                team.setOpen(line.modelData.key, line.modelData.folded)
              }
            }
            FocusRing { shown: line.focused }
          }

          // The agent that talks with the person, the head of the team.
          RowLayout {
            visible: line.modelData.kind === "front"
            anchors { fill: parent; leftMargin: Theme.space.cell; rightMargin: Theme.space.cell }
            spacing: Theme.space.gap
            Dot { Layout.alignment: Qt.AlignVCenter; tone: Omunculus.toneOf(line.modelData.front ? line.modelData.front.agent : "") }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: line.modelData.front ? line.modelData.front.agent
                + Theme.type.meta.separator + "talks with you"
                + Theme.type.meta.separator + line.modelData.front.agents + (line.modelData.front.agents === 1 ? " agent" : " agents") : ""
              color: line.modelData.front ? Omunculus.toneOf(line.modelData.front.agent) : Theme.dim
              font.pixelSize: Theme.type.body.size
              elide: Text.ElideRight
            }
            StateMark {
              visible: !!line.modelData.front
              Layout.fillWidth: false
              Layout.maximumWidth: line.width * 0.4
              state: line.modelData.front ? line.modelData.front.state : ""
              text: !line.modelData.front ? "" : line.modelData.front.state === "working" || line.modelData.front.state === "waiting" ? line.modelData.front.doing : line.modelData.front.state === "idle" ? "Idle" : ""
              clock: line.modelData.front && line.modelData.front.state === "working" && line.modelData.front.since !== null
                ? Progress.clock(Math.max(0, Math.round(Omunculus.tick - line.modelData.front.since))) : ""
            }
            Chip {
              visible: !!line.modelData.front && line.modelData.front.asking !== ""
              text: line.modelData.front ? "⇡ " + (line.width < 480 ? "" : line.modelData.front.asker + " asks you ") + line.modelData.front.asking : ""
              accent: Theme.warning
              alert: true
              onClicked: team.requestPicked("", line.modelData.front.ask)
            }
          }

          // A work, nested under the head when there is one.
          Loader {
            id: node
            active: line.modelData.kind === "work"
            x: line.indent
            y: line.lead
            width: parent.width - x
            sourceComponent: ProgressNode {
              node: line.modelData.node
              mode: "full"
              active: team.picked === line.modelData.key
              highlighted: team.linked.includes(line.modelData.key)
              folds: line.modelData.drills
              focused: line.focused
              onToggled: {
                outline.currentIndex = line.index
                outline.forceActiveFocus()
                team.choose(line.modelData.key)
              }
              onDrilled: team.drill(line.modelData.key)
              onRequestPicked: id => team.requestPicked(line.modelData.key, id)
            }
          }
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
        // Moves the keyboard `by` rows past the rules; the detail follows a work.
        function step(by) {
          let at = currentIndex + by
          while (at >= 0 && at < count && ["rule", "front"].includes(team.rows[at].kind))
            at += by
          if (at < 0 || at >= count)
            return
          currentIndex = at
          positionViewAtIndex(at, ListView.Contain)
          if (team.rows[at].kind === "work")
            team.picked = team.rows[at].key
        }
        onActiveFocusChanged: if (activeFocus && currentIndex < 0 && count > 0) currentIndex = Math.max(0, team.rowOf(team.picked))
        Keys.onUpPressed: step(-1)
        Keys.onDownPressed: step(1)
        Keys.onRightPressed: {
          const row = team.rows[currentIndex]
          if (row && row.kind === "work" && row.drills)
            team.drill(row.key)
          else if (row && row.kind === "done" && row.folded)
            team.setOpen(row.key, true)
        }
        Keys.onLeftPressed: {
          const row = team.rows[currentIndex]
          if (row && row.kind === "done" && !row.folded)
            team.setOpen(row.key, false)
          else
            team.up()
        }
        Keys.onReturnPressed: {
          const row = team.rows[currentIndex]
          if (row && row.kind === "work")
            team.open(row.key)
          else if (row && row.kind === "done")
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
      }

      Loader {
        id: mapLoader
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: team.mapShown
        active: team.mapShown
        // The canvas moves under the pane's edge, never over the detail.
        clip: true
        sourceComponent: AgentsView {
          picked: team.picked
          highlighted: team.linked
          onChosen: work => {
            if (work === "")
              return
            team.picked = work
            if (!team.wide)
              team.detailOpen = true
          }
          onRequestPicked: id => {
            const asker = team.flat.find(node => node.asks.some(ask => ask.id === id))
            team.requestPicked(asker ? asker.work : team.picked, id)
          }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: team.rows.length === 0 && !team.mapShown
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

    // Where the detail sits beside the outline or the map.
    Item {
      id: detailSlot
      Layout.fillHeight: true
      Layout.fillWidth: team.wide && !team.mapShown
      Layout.preferredWidth: team.mapShown ? (team.wide ? 420 : team.width * 0.45) : -1
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
    visible: team.picked !== "" && (team.wide || team.detailOpen || team.mapShown)
    key: team.picked
    node: team.pickedNode
    trail: (whole ? [{ text: "Conversation" }] : []).concat(team.trailOf(team.picked).map(node => ({ text: node.title || node.agent })))
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
      if (index === 0)
        team.level = ""
      else
        team.drill(chain[index - 1].work)
    }
    onPicked: key => team.wide ? team.pick(key) : team.choose(key)
    onOpenLog: work => team.openLog(work)
    onOpenMap: work => {
      team.detailOpen = false
      team.shownAs = "map"
      team.pick(work)
    }
    onDecide: (id, escalating) => team.decide(id, escalating)
  }
}
