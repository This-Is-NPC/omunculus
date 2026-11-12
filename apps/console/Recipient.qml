pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// Recipient is whom the first message goes to: "TO", then a folded control
// with the agent chosen, or, with none, who a message goes to when it is left
// empty (the project's default agent), and a chevron. Opened, it lists the
// other agents of depth 0 that are not only in workflows, those for the
// person's work first, then the project's own, each a name and its role: the
// first sentence of its text without a leading "You are the". No agent is
// chosen for the person; it is held open only while the project has no default. Up and Down move along the list, Enter picks, Esc folds
// it. A click picks too. With one agent to talk with, there is nothing to open.
FocusScope {
  id: recipient

  // Whether the list was asked for; it is shown anyway while no agent is chosen.
  property bool expanded: false
  readonly property bool listing: others.length > 0 && (expanded || (Omunculus.agent === "" && Omunculus.startAgent === ""))
  // Emitted once an agent is picked, so the box can take the keyboard.
  signal picked()

  // The agents of the pack that maintains the project itself.
  readonly property var maintainers: {
    const pack = Omunculus.setup ? (Omunculus.setup.packs || []).find(each => each.name === "system") : null
    return pack ? pack.agents : []
  }
  readonly property var others: Omunculus.talkable.filter(each => each.name !== Omunculus.agent)
  readonly property var front: others.filter(each => !maintainers.includes(each.name))
  readonly property var care: others.filter(each => maintainers.includes(each.name))
  // The list in the order of the keys: the front ones, then the others.
  readonly property var choices: front.concat(care)
  // The row the keyboard is on, by its place in `choices`.
  property int at: 0
  onChoicesChanged: at = Math.min(at, Math.max(0, choices.length - 1))

  // The role of an agent: the first sentence of its text without "You are the".
  function role(text) {
    const sentence = (text || "").split(/[.:\n]/)[0].replace(/^\s*You are( the| an?)?\s+/i, "").trim()
    return sentence.charAt(0).toUpperCase() + sentence.slice(1)
  }

  function pick(name) {
    Omunculus.agent = name
    expanded = false
    picked()
  }

  function toggle() {
    if (others.length === 0)
      return
    expanded = !expanded
    at = 0
  }

  implicitHeight: column.implicitHeight

  ColumnLayout {
    id: column
    anchors { left: parent.left; right: parent.right }
    spacing: Theme.space.tight

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap

      Label {
        text: "TO"
        color: Theme.dim
        font.pixelSize: Theme.type.kicker.size
        font.letterSpacing: Theme.type.kicker.tracking
      }

      Rectangle {
        id: control
        Layout.preferredHeight: Theme.size.chip
        implicitWidth: who.implicitWidth + 34 + (Omunculus.agent !== "" ? 14 : 0)
        color: recipient.listing ? Qt.alpha(Theme.primary, 0.12) : pointer.containsMouse ? Qt.alpha(Theme.primary, 0.05) : "transparent"
        border.color: recipient.listing ? Theme.primary : pointer.containsMouse ? Theme.dim : Theme.line
        activeFocusOnTab: true
        focus: true
        Accessible.role: Accessible.ComboBox
        Accessible.name: "to " + (Omunculus.agent || "nobody chosen")
        Keys.onPressed: event => {
          const enter = [Qt.Key_Return, Qt.Key_Enter].includes(event.key)
          const choice = recipient.choices[recipient.at]
          if (event.key === Qt.Key_Escape && recipient.expanded)
            recipient.expanded = false
          else if (recipient.listing && event.key === Qt.Key_Down)
            recipient.at = Math.min(recipient.choices.length - 1, recipient.at + 1)
          else if (recipient.listing && event.key === Qt.Key_Up)
            recipient.at = Math.max(0, recipient.at - 1)
          else if (recipient.listing && enter && choice)
            recipient.pick(choice.name)
          else if (enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down)
            recipient.toggle()
          else
            return
          event.accepted = true
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          x: 10
          spacing: Theme.space.tight
          Dot {
            anchors.verticalCenter: parent.verticalCenter
            visible: Omunculus.agent !== ""
            tone: Omunculus.toneOf(Omunculus.agent)
          }
          Label {
            id: who
            anchors.verticalCenter: parent.verticalCenter
            text: Omunculus.agent !== "" ? Omunculus.agent.toUpperCase() : Omunculus.startHint !== "" ? Omunculus.startHint.toUpperCase() : "CHOOSE WHO"
            color: Omunculus.agent !== "" ? Theme.foreground : Theme.dim
            font.pixelSize: 11
            font.letterSpacing: 1.5
          }
        }
        Icon {
          anchors { right: parent.right; rightMargin: Theme.space.gap; verticalCenter: parent.verticalCenter }
          visible: recipient.others.length > 0
          name: "chevron-down"
          size: 11
          color: Theme.dim
          rotation: recipient.listing ? 180 : 0
          Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
        FocusRing { shown: control.activeFocus }
        MouseArea {
          id: pointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: recipient.others.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            control.forceActiveFocus()
            recipient.toggle()
          }
        }
      }
      Item { Layout.fillWidth: true }
    }

    Column {
      id: list
      Layout.fillWidth: true
      visible: recipient.listing
      spacing: 0

      Repeater {
        model: recipient.choices
        delegate: Column {
          id: entry
          required property var modelData
          required property int index
          readonly property bool current: recipient.at === index && control.activeFocus
          width: list.width

          Kicker { width: parent.width; visible: entry.index === 0; text: "SEND TO" }
          Kicker { width: parent.width; visible: recipient.care.length > 0 && entry.index === recipient.front.length; text: "FOR THE PROJECT ITSELF" }
          Rectangle {
            width: parent.width
            height: Math.max(Theme.size.control, line.implicitHeight + Theme.space.tight * 2)
            color: entry.current || rowPointer.containsMouse ? Theme.highlight : "transparent"
            border.color: entry.current ? Theme.primary : "transparent"

            RowLayout {
              id: line
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
              spacing: Theme.space.gap
              Dot { Layout.alignment: Qt.AlignVCenter; tone: Omunculus.toneOf(entry.modelData.name) }
              Label {
                Layout.preferredWidth: 130
                text: entry.modelData.name.toUpperCase()
                color: Theme.foreground
                font.pixelSize: Theme.type.tab.size
                font.letterSpacing: Theme.type.name.tracking
                elide: Text.ElideRight
              }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: recipient.role(entry.modelData.text)
                color: Theme.dim
                font.pixelSize: Theme.type.body.size
                elide: Text.ElideRight
              }
            }
            MouseArea {
              id: rowPointer
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPressed: hint.dismiss()
              onClicked: recipient.pick(entry.modelData.name)
            }
            Hint { id: hint; active: rowPointer.containsMouse; text: "runs on " + Omunculus.modelOf(entry.modelData.name) }
          }
        }
      }
      Label {
        width: parent.width
        topPadding: Theme.space.tight
        text: "Opt-in: only agents without a parent are listed."
        color: Theme.faint
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
      }
    }
  }
}
