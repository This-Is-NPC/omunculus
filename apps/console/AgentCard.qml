pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// AgentCard is one agent as it runs in a place of the overview: its name in its
// colour, the model it runs on with the options sent with every request, where
// its provider's key comes from, and the names its layer lists as the ceiling
// has them there; then its skills, each joined by a line to the tools it uses.
// What the place changes reads in violet with the place's name; an agent no
// stage runs there shows hollow.
Rectangle {
  id: card

  required property var agent
  // The workspace the card is drawn in, or "" for the project root.
  property string place: ""
  signal picked()

  readonly property var model: agent.model
  // Tool name -> its chip, and skill name -> its card, as they are made; the
  // lines between them read their places.
  property var chips: ({})
  property var skillCards: ({})
  // Counts the chips and cards made, so what reads them reads them again.
  property int placed: 0

  function place_(map, name, item) {
    map[name] = item
    placed++
    Qt.callLater(links.requestPaint)
  }
  function forget(map, name, item) {
    if (map[name] === item)
      delete map[name]
  }
  // Whether the agent has the tool `name` here, on its own or in a group.
  function has(name) {
    const tools = agent.tools || []
    return tools.some(tool => tool.state === "have" && (tool.name === name || (tool.members || []).includes(name)))
  }

  // The chip that holds the tool `name`: its own, or the group it belongs to.
  function chipFor(name) {
    if (chips[name])
      return chips[name]
    const tools = agent.tools || []
    const group = tools.find(tool => (tool.members || []).includes(name))
    return group ? chips[group.name] || null : null
  }
  // The options as "key.sub=value" lines, nested tables opened.
  readonly property var options: {
    const lines = []
    const walk = (table, prefix) => {
      for (const key of Object.keys(table || {})) {
        const value = table[key]
        if (value !== null && typeof value === "object" && !Array.isArray(value))
          walk(value, prefix + key + ".")
        else
          lines.push(prefix + key + "=" + (typeof value === "string" ? value : JSON.stringify(value)))
      }
    }
    walk(model.body, "")
    return lines
  }

  implicitHeight: body.implicitHeight + 18
  color: pointer.containsMouse ? Theme.highlight : Qt.tint(Theme.background, Qt.alpha(Theme.foreground, 0.03))
  border.color: pointer.containsMouse ? Theme.primary : Theme.line
  opacity: agent.idle ? 0.55 : 1
  Behavior on color { ColorAnimation { duration: 140 } }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: card.picked()
  }

  // The lines from each skill to the tools it uses, under the chips and cards.
  Canvas {
    id: links
    anchors.fill: parent
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      const context = getContext("2d")
      context.reset()
      context.strokeStyle = String(Qt.alpha(Theme.primary, 0.55))
      context.lineWidth = 1
      for (const skill of card.agent.skills || []) {
        const from = card.skillCards[skill.name]
        if (!from)
          continue
        const start = from.mapToItem(links, from.width / 2, 0)
        for (const use of skill.uses) {
          const to = card.chipFor(use)
          if (!to)
            continue
          const end = to.mapToItem(links, to.width / 2, to.height)
          const bend = (start.y - end.y) / 2
          context.beginPath()
          context.moveTo(start.x, start.y)
          context.bezierCurveTo(start.x, start.y - bend, end.x, end.y + bend, end.x, end.y)
          context.stroke()
        }
      }
    }
  }

  ColumnLayout {
    id: body
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9; leftMargin: 11; rightMargin: 11 }
    spacing: 4

    RowLayout {
      spacing: 7
      Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 3.5; color: Omunculus.toneOf(card.agent.name) }
      Label { text: card.agent.name; color: Omunculus.toneOf(card.agent.name); font.pixelSize: 12; font.letterSpacing: 1 }
    }

    // What it runs on.
    Flow {
      Layout.fillWidth: true
      spacing: 6
      Label { text: "MODEL"; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2; width: 40 }
      ChangeMark { visible: card.model.changed && card.place !== ""; text: card.place }
      Label { text: card.model.name; color: Theme.secondary; font.pixelSize: 11 }
      Label { text: (card.model.id || "") + "  ·  " + card.model.api; color: Theme.dim; font.pixelSize: 10 }
      Repeater {
        model: card.options
        delegate: Rectangle {
          required property string modelData
          implicitWidth: option.implicitWidth + 8
          implicitHeight: 15
          color: "transparent"
          border.color: Qt.alpha(Theme.magenta, 0.45)
          Label { id: option; anchors.centerIn: parent; text: parent.modelData; color: Theme.magenta; font.pixelSize: 9 }
        }
      }
    }

    // Where its provider's key comes from.
    Flow {
      Layout.fillWidth: true
      visible: card.agent.key !== null
      spacing: 6
      Label { text: "KEY"; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2; width: 40 }
      Label { text: card.agent.key ? card.agent.key.provider : ""; color: Theme.secondary; font.pixelSize: 11 }
      Label { text: card.agent.key ? card.agent.key.source : ""; color: Theme.dim; font.pixelSize: 10 }
    }

    Flow {
      Layout.fillWidth: true
      Layout.topMargin: 3
      spacing: 3
      Repeater {
        model: card.agent.tools
        delegate: ToolChip {
          id: chip
          required property var modelData
          tool: modelData
          Component.onCompleted: card.place_(card.chips, chip.tool.name, chip)
          Component.onDestruction: card.forget(card.chips, chip.tool.name, chip)
        }
      }
    }

    // Its skills, each a card of its own, joined by a line to each tool it uses.
    ColumnLayout {
      Layout.fillWidth: true
      Layout.topMargin: 14
      visible: card.agent.skills.length > 0
      spacing: 5
      Label { text: "SKILLS"; color: Theme.dim; font.pixelSize: 9; font.letterSpacing: 2 }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
          model: card.agent.skills
          delegate: SkillCard {
            id: skillCard
            required property var modelData
            skill: modelData
            had: name => card.placed >= 0 && card.has(name)
            Component.onCompleted: card.place_(card.skillCards, skillCard.skill.name, skillCard)
            Component.onDestruction: card.forget(card.skillCards, skillCard.skill.name, skillCard)
          }
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.agent.idle
      text: "workflow only — no workflow at this depth runs it here"
      color: Theme.warning
      font.pixelSize: 10
      wrapMode: Text.Wrap
    }
  }
}
