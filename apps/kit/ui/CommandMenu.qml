pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C

// CommandMenu lists commands under the control that opens it, its parent: a
// row each, its icon, its name and the key that runs it. It stays inside the
// window, at most 280 px wide. It takes the keyboard while open: Up and Down
// move, Enter or Space runs the one picked, Esc closes it; a click runs one.
// Running one closes the menu first, so what it opens keeps the keyboard.
C.Popup {
  id: menu

  // [{text, icon, tip, key, role, tone, checked, enabled, run}], in order.
  property var commands: []
  // The command to run once the menu has closed.
  property var chosen: null

  readonly property Item overlay: C.Overlay.overlay

  // Under its control, moved inside the window's margins when it would leave.
  x: 0
  y: parent ? parent.height + 4 : 0
  margins: 8
  width: Math.min(280, (overlay ? overlay.width : 296) - 16)
  padding: 4
  focus: true
  closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutsideParent
  FocusKeeper { popup: menu }

  function run(command) {
    if (!command || command.enabled === false)
      return
    chosen = command
    close()
  }

  onAboutToShow: list.currentIndex = commands.findIndex(command => command.enabled !== false)
  onOpened: list.forceActiveFocus()
  onClosed: if (chosen) {
    const command = chosen
    chosen = null
    Qt.callLater(command.run)
  }

  background: Rectangle { color: Theme.background; border.color: Qt.alpha(Theme.foreground, 0.35) }
  enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.reducedMotion ? 0 : 110 } }

  contentItem: ListView {
    id: list
    implicitHeight: contentHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: menu.commands
    keyNavigationEnabled: true
    Keys.onReturnPressed: menu.run(menu.commands[currentIndex])
    Keys.onEnterPressed: menu.run(menu.commands[currentIndex])
    Keys.onSpacePressed: menu.run(menu.commands[currentIndex])

    delegate: Rectangle {
      id: entry
      required property var modelData
      required property int index
      readonly property bool picked: ListView.isCurrentItem && list.activeFocus
      readonly property bool usable: modelData.enabled !== false
      readonly property color tone: modelData.tone || (modelData.role === "guarded" ? Theme.error : modelData.checked ? Theme.primary : Theme.foreground)

      width: ListView.view.width
      height: 40
      opacity: usable ? 1 : 0.35
      color: pointer.containsMouse && usable || picked ? Theme.highlight : "transparent"
      border.color: picked ? Theme.primary : "transparent"

      RowLayout {
        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
        spacing: 10
        Icon {
          Layout.alignment: Qt.AlignVCenter
          implicitWidth: 12
          implicitHeight: 12
          name: entry.modelData.checked ? "check" : entry.modelData.icon || ""
          size: 12
          color: entry.tone
        }
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: entry.modelData.text
          color: entry.tone
          font.pixelSize: 11
          font.letterSpacing: 1
          font.bold: !!entry.modelData.checked
          elide: Text.ElideRight
        }
        Label {
          Layout.maximumWidth: entry.width / 3
          visible: !!entry.modelData.key
          text: String(entry.modelData.key || "").toLowerCase()
          color: Theme.dim
          font.pixelSize: 10
          elide: Text.ElideRight
        }
      }

      MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: entry.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: menu.run(entry.modelData)
      }
      Hint { active: pointer.containsMouse; text: entry.modelData.tip || "" }
    }
  }
}
