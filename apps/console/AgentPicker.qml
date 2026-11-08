pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Shortcuts.js" as Shortcuts
import "kit/ui"

// AgentPicker is whom a new conversation is with, under the question, left
// as every page is: the agents of depth 0 that are not only in workflows, in
// two groups. First, for your work, the project's own — a card each, filling
// the width as many a row as fit, with its portrait, its name and its role,
// the first sentence of its text. Then, smaller, for the project itself, the
// agents of the system pack, which change how the project's agents work,
// each change only once you approve it: a line each, its portrait and its
// name, its role in the tip. The agent last talked to comes first in its
// group, marked; the keyboard is on it, else on the first card, its ring
// showing which one Enter opens. A click, a number (said in the tip), or the
// arrows and Enter pick one; Esc goes back.
FocusScope {
  id: picker

  signal picked(string name)
  signal back()

  // The agents of the pack that maintains the project itself.
  readonly property var maintainers: {
    const pack = Omunculus.setup ? (Omunculus.setup.packs || []).find(each => each.name === "system") : null
    return pack ? pack.agents : []
  }
  // The last agent talked to first, the others in the order of the setup.
  function lastFirst(list) {
    const last = list.find(each => each.name === Omunculus.lastAgent)
    return last ? [last].concat(list.filter(each => each !== last)) : list
  }
  readonly property var front: lastFirst(Omunculus.talkable.filter(each => !maintainers.includes(each.name)))
  readonly property var care: lastFirst(Omunculus.talkable.filter(each => maintainers.includes(each.name)))
  // Every agent in the order of the keys: the front ones, then the others.
  readonly property var agents: front.concat(care)

  // The card the keyboard is on, by its place in `agents`.
  property int at: 0
  readonly property int start: Math.max(0, agents.findIndex(each => each.name === Omunculus.lastAgent))
  onVisibleChanged: if (visible) at = start
  onAgentsChanged: at = start

  // The widths a card, and a line of the second group, are made from.
  readonly property real cardMinimum: 200
  readonly property real lineMinimum: 240
  readonly property real gap: Theme.space.gap
  function across(minimum) { return Math.max(1, Math.floor((cards.width + gap) / (minimum + gap))) }
  readonly property int frontAcross: across(cardMinimum)
  readonly property int careAcross: across(lineMinimum)
  readonly property real cardWidth: Math.floor((cards.width - (frontAcross - 1) * gap) / frontAcross)
  readonly property real lineWidth: Math.floor((cards.width - (careAcross - 1) * gap) / careAcross)
  // A card's portrait, shorter than it is wide, then its name and three
  // lines of its role.
  readonly property real portraitHeight: Math.round(Math.min(cardWidth * 0.75, 3 * cardMinimum / 4))
  readonly property real info: 2 * Theme.space.insetTop + nameFont.height + Theme.space.line + 3 * roleFont.height
  // A line of the second group: its name and two lines of its role.
  readonly property real lineHeight: 2 * Theme.space.insetTop + nameFont.height + Theme.space.line + 2 * roleFont.height
  FontMetrics { id: nameFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.cardBody.size }
  FontMetrics { id: roleFont; font.family: Theme.fontFamily; font.pixelSize: Theme.type.body.size }

  // The role of an agent: the first sentence of its text without "You are the".
  function role(text) {
    const sentence = (text || "").split(/[.:\n]/)[0].replace(/^\s*You are( the| an?)?\s+/i, "").trim()
    return sentence.charAt(0).toUpperCase() + sentence.slice(1)
  }
  // A card's tip: the model it runs on, and its key.
  function tipOf(agent, index) {
    const key = index < Shortcuts.keys("pick").length ? "press " + Shortcuts.keys("pick")[index] : ""
    return ["runs on " + Omunculus.modelOf(agent.name), key].filter(text => text !== "").join("  ·  ")
  }

  // The arrows move along the agents; up and down by a row of the group, and
  // from the last row of the first group to the second, and back.
  function move(key) {
    const inFront = at < front.length
    const column = inFront ? at % frontAcross : (at - front.length) % careAcross
    if (key === Qt.Key_Left)
      at = Math.max(0, at - 1)
    else if (key === Qt.Key_Right)
      at = Math.min(agents.length - 1, at + 1)
    else if (key === Qt.Key_Down)
      at = inFront && at + frontAcross < front.length ? at + frontAcross
        : inFront && care.length > 0 ? front.length + Math.min(column, care.length - 1)
        : !inFront && at + careAcross < agents.length ? at + careAcross : at
    else if (key === Qt.Key_Up)
      at = !inFront && at - careAcross >= front.length ? at - careAcross
        : !inFront && front.length > 0 ? Math.min(front.length - 1, Math.floor((front.length - 1) / frontAcross) * frontAcross + column)
        : inFront && at - frontAcross >= 0 ? at - frontAcross : at
    else
      return false
    return true
  }
  // Scrolls the card the keyboard is on into view.
  function reveal() {
    const item = at < front.length ? frontCards.itemAt(at) : careLines.itemAt(at - front.length)
    if (!item)
      return
    const top = item.mapToItem(scroll.contentItem, 0, 0).y
    if (top < scroll.contentY)
      scroll.contentY = top
    else if (top + item.height > scroll.contentY + scroll.height)
      scroll.contentY = top + item.height - scroll.height
  }
  onAtChanged: Qt.callLater(reveal)

  Keys.onEscapePressed: back()

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block

    Label {
      Layout.fillWidth: true
      text: "Who do you want to talk with?"
      color: Theme.foreground
      font.pixelSize: Theme.type.cardBody.size
      elide: Text.ElideRight
    }

    Flickable {
      id: scroll
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: width
      contentHeight: cards.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: cards
        width: scroll.width
        spacing: Theme.space.block
        // The cards hold the keyboard: the digits pick only with no text
        // just written.
        focus: true
        Keys.onPressed: event => {
          if (picker.move(event.key)) {
            event.accepted = true
            return
          }
          if (!Typing.idle)
            return
          const index = Shortcuts.keys("pick").indexOf(event.text)
          if (index >= 0 && index < picker.agents.length) {
            picker.picked(picker.agents[index].name)
            event.accepted = true
          }
        }
        Keys.onReturnPressed: if (picker.agents.length > 0) picker.picked(picker.agents[picker.at].name)
        Keys.onEnterPressed: if (picker.agents.length > 0) picker.picked(picker.agents[picker.at].name)

        Kicker {
          width: parent.width
          visible: picker.front.length > 0 && picker.care.length > 0
          text: "FOR YOUR WORK"
        }

        Flow {
          width: parent.width
          spacing: picker.gap
          Repeater {
            id: frontCards
            model: picker.front
            delegate: Rectangle {
              id: cardItem
              required property var modelData
              required property int index
              readonly property bool current: picker.at === index && cards.activeFocus
              width: picker.cardWidth
              height: picker.portraitHeight + picker.info
              color: current || pointer.containsMouse ? Theme.highlight : "transparent"
              border.color: pointer.containsMouse ? Qt.alpha(Theme.primary, 0.5) : Theme.line
              Behavior on border.color { ColorAnimation { duration: 140 } }

              Portrait {
                id: portrait
                x: 1
                y: 1
                width: parent.width - 2
                height: picker.portraitHeight
                agent: cardItem.modelData.name
                source: Omunculus.imageOf(cardItem.modelData.name)
                tone: Omunculus.toneOf(cardItem.modelData.name)
              }
              Label {
                anchors { right: parent.right; top: parent.top; margins: Theme.space.tight }
                visible: cardItem.modelData.name === Omunculus.lastAgent
                text: "LAST USED"
                color: Theme.primary
                font.pixelSize: Theme.type.header.size
                font.letterSpacing: Theme.type.header.tracking
                padding: Theme.space.line
                Rectangle { anchors.fill: parent; z: -1; color: Theme.background; border.color: Theme.line }
              }

              Column {
                anchors { left: parent.left; right: parent.right; top: portrait.bottom; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset; topMargin: Theme.space.insetTop }
                spacing: Theme.space.line
                Row {
                  width: parent.width
                  spacing: Theme.space.tight
                  Dot {
                    anchors.verticalCenter: parent.verticalCenter
                    tone: Omunculus.toneOf(cardItem.modelData.name)
                  }
                  DecodeLabel {
                    width: parent.width - x
                    value: cardItem.modelData.name.toUpperCase()
                    color: Theme.foreground
                    font.pixelSize: Theme.type.cardBody.size
                    font.letterSpacing: Theme.type.name.tracking
                    elide: Text.ElideRight
                  }
                }
                Label {
                  width: parent.width
                  text: picker.role(cardItem.modelData.text)
                  color: Theme.dim
                  font.pixelSize: Theme.type.body.size
                  wrapMode: Text.Wrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: hint.dismiss()
                onClicked: picker.picked(cardItem.modelData.name)
              }
              Hint { id: hint; active: pointer.containsMouse; text: picker.tipOf(cardItem.modelData, cardItem.index) }
              FocusRing { shown: cardItem.current }
            }
          }
        }

        Column {
          width: parent.width
          visible: picker.care.length > 0
          spacing: Theme.space.tight
          Kicker {
            width: parent.width
            visible: picker.front.length > 0
            text: "FOR THE PROJECT ITSELF"
          }
          Label {
            width: parent.width
            text: "They change how the agents of this project work; nothing changes until you approve it."
            color: Theme.dim
            font.pixelSize: Theme.type.body.size
            wrapMode: Text.Wrap
          }
        }

        Flow {
          width: parent.width
          spacing: picker.gap
          Repeater {
            id: careLines
            model: picker.care
            delegate: Rectangle {
              id: line
              required property var modelData
              required property int index
              readonly property int place: picker.front.length + index
              readonly property bool current: picker.at === place && cards.activeFocus
              width: picker.lineWidth
              height: picker.lineHeight
              color: current || linePointer.containsMouse ? Theme.highlight : "transparent"
              border.color: linePointer.containsMouse ? Qt.alpha(Theme.primary, 0.5) : Theme.line
              Behavior on border.color { ColorAnimation { duration: 140 } }

              Portrait {
                id: face
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                width: height
                agent: line.modelData.name
                source: Omunculus.imageOf(line.modelData.name)
                tone: Omunculus.toneOf(line.modelData.name)
              }
              Column {
                anchors { left: face.right; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
                spacing: Theme.space.line
                Row {
                  width: parent.width
                  spacing: Theme.space.tight
                  Dot {
                    anchors.verticalCenter: parent.verticalCenter
                    tone: Omunculus.toneOf(line.modelData.name)
                  }
                  Label {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x
                    text: line.modelData.name.toUpperCase() + (line.modelData.name === Omunculus.lastAgent ? Theme.type.meta.separator + "LAST USED" : "")
                    color: Theme.foreground
                    font.pixelSize: Theme.type.tab.size
                    font.letterSpacing: Theme.type.name.tracking
                    elide: Text.ElideRight
                  }
                }
                Label {
                  width: parent.width
                  text: picker.role(line.modelData.text)
                  color: Theme.dim
                  font.pixelSize: Theme.type.body.size
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: linePointer
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: lineHint.dismiss()
                onClicked: picker.picked(line.modelData.name)
              }
              Hint { id: lineHint; active: linePointer.containsMouse; text: picker.tipOf(line.modelData, line.place) }
              FocusRing { shown: line.current }
            }
          }
        }
      }
    }

    Label {
      Layout.fillWidth: true
      visible: picker.agents.length === 0
      text: Omunculus.setup ? "No agent here takes a conversation." : "reading the project"
      color: Theme.dim
    }
  }
}
