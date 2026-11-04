pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "kit/ui"

// AgentsView is the TEAM page's map: the conversation's works as a chart on
// a canvas that moves and zooms. You sit on top; each work is one card
// (AgentNode), its children under it, grouped by the stage of the parent
// that handed them down, each group named, "2 in parallel" when it holds
// several. A link flows while the work below it runs. Only the requests of
// the work picked are drawn, from the asker to whoever decides; every card
// carries its own ⇡/⇣ badges. Agents with nothing to do show only when asked
// for. Framing never goes below the actual size; the canvas scrolls instead.
Item {
  id: view

  // The work picked, or "" for none.
  property string picked: ""
  // The works at either end of the request picked.
  property var highlighted: []
  property bool showIdle: false
  signal chosen(string work)
  signal requestPicked(string id)

  readonly property var progress: Omunculus.progress
  readonly property var roots: progress ? progress.roots : []
  readonly property var flat: progress ? progress.flat : []

  function fit() { map.fit() }

  readonly property int cardWidth: 240
  readonly property int cardHeight: 96
  readonly property int across: 24
  readonly property int groupGap: 48
  readonly property int down: 72
  readonly property int youWidth: 160
  readonly property int youHeight: 44
  readonly property int idleWidth: 160
  readonly property int idleHeight: 40
  function rowTop(level) { return youHeight + down + level * (cardHeight + down) }

  // Where each card sits, work id -> {x, y}; the groups' names, {x, y,
  // width, text}; and the links, {from ("" for you), to, running}. Each subtree is as
  // wide as its card or its groups side by side, a card centred over its
  // children.
  readonly property var layout: {
    const span = {}
    const groupSpans = {}
    const measure = node => {
      const widths = node.groups.map(group =>
        group.nodes.reduce((sum, kid) => sum + measure(kid), 0) + Math.max(0, group.nodes.length - 1) * across)
      groupSpans[node.work] = widths
      const row = widths.reduce((sum, width) => sum + width, 0) + Math.max(0, widths.length - 1) * groupGap
      return span[node.work] = Math.max(cardWidth, row)
    }
    const places = {}
    const labels = []
    const links = []
    const lay = (node, left, level) => {
      const widths = groupSpans[node.work]
      const row = widths.reduce((sum, width) => sum + width, 0) + Math.max(0, widths.length - 1) * groupGap
      let x = left + (span[node.work] - row) / 2
      const centres = []
      node.groups.forEach((group, i) => {
        const counts = group.counts
        const name = (group.step ? group.step + " stage" : "")
        const together = group.parallel ? group.nodes.length + " in parallel" + (counts.working ? " · " + counts.working + " working" : "") + (counts.done ? " · " + counts.done + " done" : "") : ""
        if (name || together)
          labels.push({ x: x, y: rowTop(level + 1) - 24, width: widths[i], text: [name, together].filter(part => part).join(" · ") })
        for (const kid of group.nodes) {
          centres.push(lay(kid, x, level + 1) + cardWidth / 2)
          x += span[kid.work] + across
        }
        x += groupGap - across
      })
      const centre = centres.length > 0 ? (centres[0] + centres[centres.length - 1]) / 2 : left + span[node.work] / 2
      const at = Math.max(left, Math.min(left + span[node.work] - cardWidth, centre - cardWidth / 2))
      places[node.work] = { x: at, y: rowTop(level) }
      for (const kid of node.groups.reduce((all, group) => all.concat(group.nodes), []))
        links.push({ from: node.work, to: kid.work, running: kid.state === "working" })
      return at
    }
    let left = 0
    for (const root of roots) {
      measure(root)
      lay(root, left, 0)
      links.push({ from: "", to: root.work, running: root.state === "working" })
      left += span[root.work] + across
    }
    const wide = Math.max(youWidth, left - across)
    const deepest = Math.max(-1, ...flat.map(node => node.level))
    return { places: places, labels: labels, links: links, wide: wide, bottom: rowTop(deepest + 1) - down + (deepest < 0 ? down : 0) }
  }
  readonly property real youX: layout.wide / 2 - youWidth / 2

  // The configured agents with nothing in this conversation.
  readonly property var idle: {
    if (!showIdle || !Omunculus.setup)
      return []
    const busy = new Set(flat.map(node => node.agent))
    return Omunculus.setup.agents.filter(agent => !agent.workflow_only && !busy.has(agent.name)).map(agent => agent.name)
  }
  readonly property real idleY: layout.bottom + 40
  readonly property real wide: Math.max(layout.wide, idle.length * (idleWidth + across))
  readonly property real tall: idle.length > 0 ? idleY + idleHeight : layout.bottom

  // The box of a work's card, in the chart's coordinates.
  function cardOf(work) {
    const place = layout.places[work]
    return place ? { x: place.x, y: place.y, width: cardWidth, height: cardHeight } : null
  }

  // The picked work's requests: from the asker's card to whoever decides.
  readonly property var arrows: {
    const node = flat.find(each => each.work === picked)
    if (!node)
      return []
    const edge = (from, to, human) => {
      const a = layout.places[from]
      const b = human ? { x: youX, y: 0, you: true } : layout.places[to]
      if (!a || !b)
        return null
      return {
        x1: a.x + cardWidth * 0.8, y1: a.y,
        x2: b.x + (b.you ? youWidth : cardWidth) * 0.8, y2: b.y + (b.you ? youHeight : cardHeight), human: human
      }
    }
    return node.asks.map(ask => edge(node.work, ask.toWork, ask.human))
      .concat(node.asked.map(ask => edge(ask.fromWork, node.work, false)))
      .filter(arrow => arrow !== null)
  }

  // The card the keyboard reaches comes into view.
  readonly property Item focused: Window.activeFocusItem
  onFocusedChanged: {
    for (let item = focused; item; item = item.parent) {
      if (item === map.world) {
        const at = focused.mapToItem(map.world, 0, 0)
        map.bringIntoView({ x: at.x, y: at.y, width: focused.width, height: focused.height })
        return
      }
    }
  }
  onPickedChanged: if (cardOf(picked)) Qt.callLater(() => map.bringIntoView(cardOf(picked)))

  FlowCanvas {
    id: map
    anchors.fill: parent
    contentWidth: view.wide
    contentHeight: view.tall + 40
    topInset: idleChip.height + 8
    bottomInset: zoom.height + 16
    onBackgroundClicked: view.chosen("")
    // Fitting never goes below the actual size, where the text stays at its
    // size; the canvas scrolls instead.
    onFramed: {
      if (world.scale < 1) {
        world.scale = 1
        world.x = leftInset + 20
        world.y = topInset + 20
      }
      if (view.cardOf(view.picked))
        bringIntoView(view.cardOf(view.picked))
    }
    onContentWidthChanged: if (!moved) Qt.callLater(fit)
    onContentHeightChanged: if (!moved) Qt.callLater(fit)

    Item {
      id: canvas
      width: view.wide
      height: view.tall

      // Links: you to each top work, each work to those it handed down.
      Repeater {
        model: view.layout.links
        delegate: Shape {
          id: link
          required property var modelData
          readonly property bool you: modelData.from === ""
          readonly property var from: you ? { x: view.youX + (view.youWidth - view.cardWidth) / 2, y: 0 } : view.layout.places[modelData.from] || { x: 0, y: 0 }
          readonly property real foot: you ? view.youHeight : view.cardHeight
          readonly property var to: view.layout.places[modelData.to] || { x: 0, y: 0 }
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            strokeColor: link.modelData.running ? Theme.primary : Theme.line
            strokeWidth: link.modelData.running ? 1.5 : 1
            fillColor: "transparent"
            strokeStyle: link.modelData.running ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: [3, 3]
            startX: link.from.x + view.cardWidth / 2
            startY: link.from.y + link.foot
            PathCubic {
              x: link.to.x + view.cardWidth / 2
              y: link.to.y
              control1X: link.from.x + view.cardWidth / 2
              control1Y: link.from.y + link.foot + view.down / 2
              control2X: link.to.x + view.cardWidth / 2
              control2Y: link.to.y - view.down / 2
            }
            // The dashes flow down while the work below runs.
            NumberAnimation on dashOffset {
              running: link.modelData.running && !Theme.reducedMotion
              loops: Animation.Infinite
              from: 6
              to: 0
              duration: 500
            }
          }
        }
      }

      // The groups' names, over the cards they hold.
      Repeater {
        model: view.layout.labels
        delegate: Label {
          required property var modelData
          x: modelData.x
          y: modelData.y
          width: modelData.width
          text: modelData.text
          color: Theme.dim
          font.pixelSize: 11
          elide: Text.ElideRight
        }
      }

      // You.
      Rectangle {
        x: view.youX
        y: 0
        width: view.youWidth
        height: view.youHeight
        color: Theme.background
        border.color: view.progress && view.progress.forYou.length > 0 ? Theme.warning : Theme.primary
        border.width: view.progress && view.progress.forYou.length > 0 ? 2 : 1
        Label {
          anchors.centerIn: parent
          text: "You"
          color: Theme.primary
          font.pixelSize: 13
          font.bold: true
        }
      }

      // Each work, one card.
      Repeater {
        model: view.flat
        delegate: AgentNode {
          required property var modelData
          readonly property var place: view.layout.places[modelData.work] || { x: 0, y: 0 }
          x: place.x
          y: place.y
          node: modelData
          selected: view.picked === modelData.work
          highlighted: view.highlighted.includes(modelData.work)
          onChosen: view.chosen(modelData.work)
          onRequestPicked: id => view.requestPicked(id)
        }
      }

      // The requests of the work picked.
      Repeater {
        model: view.arrows
        delegate: Item {
          id: arrow
          required property var modelData
          anchors.fill: parent
          readonly property color tone: modelData.human ? Theme.warning : Theme.dim
          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              strokeColor: arrow.tone
              strokeWidth: 1.5
              fillColor: "transparent"
              startX: arrow.modelData.x1
              startY: arrow.modelData.y1
              PathCubic {
                x: arrow.modelData.x2
                y: arrow.modelData.y2
                control1X: arrow.modelData.x1 + 36
                control1Y: arrow.modelData.y1 - view.down / 2
                control2X: arrow.modelData.x2 + 36
                control2Y: arrow.modelData.y2 + view.down / 2
              }
            }
          }
          Rectangle {
            x: arrow.modelData.x2 - 3
            y: arrow.modelData.y2 - 3
            width: 6
            height: 6
            radius: 3
            color: arrow.tone
          }
        }
      }

      // The agents with nothing to do, when asked for.
      Repeater {
        model: view.idle
        delegate: Rectangle {
          id: idler
          required property string modelData
          required property int index
          x: index * (view.idleWidth + view.across)
          y: view.idleY
          width: view.idleWidth
          height: view.idleHeight
          color: "transparent"
          border.color: Theme.line
          Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
            spacing: 8
            Portrait {
              width: 24
              height: 24
              agent: idler.modelData
              source: Omunculus.imageOf(idler.modelData)
              tone: Omunculus.toneOf(idler.modelData)
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: view.idleWidth - 48
              text: idler.modelData + " · idle"
              color: Theme.dim
              font.pixelSize: 11
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  Chip {
    id: idleChip
    anchors { left: parent.left; top: parent.top; margins: 8 }
    text: "SHOW IDLE AGENTS"
    checked: view.showIdle
    tip: "the agents configured with nothing in this conversation"
    onClicked: view.showIdle = !view.showIdle
  }

  Label {
    anchors.centerIn: parent
    visible: view.flat.length === 0
    text: "No work in this conversation yet."
    color: Theme.dim
    font.pixelSize: 12
  }

  ZoomControl {
    id: zoom
    anchors { left: parent.left; bottom: parent.bottom }
    target: map
  }
}
