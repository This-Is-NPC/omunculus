import QtQuick
import Quickshell
import "kit/ui"

ShellRoot {
  // An icon pressed on its own, without a frame, as the zoom's are; the
  // keyboard reaches it and Enter or Space presses it.
  component Glyph: Item {
    id: glyph
    property string name
    signal clicked()
    width: 36
    height: 36
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    Icon {
      anchors.centerIn: parent
      name: glyph.name
      size: 12
      color: pointer.containsMouse || glyph.activeFocus ? Theme.primary : Theme.dim
      Behavior on color { ColorAnimation { duration: 150 } }
    }
    MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: glyph.clicked() }
    FocusRing {}
  }

  // A word pressed as a link, as the projects in the corner are; the
  // keyboard reaches it, and its hit area is larger than its letters.
  component Link: DecodeLabel {
    id: link
    property bool current: false
    signal clicked()
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onSpacePressed: clicked()
    color: current ? Theme.primary : linkPointer.containsMouse || activeFocus ? Theme.foreground : Theme.dim
    font.pixelSize: 11
    font.letterSpacing: 4
    MouseArea { id: linkPointer; anchors { fill: parent; margins: -12 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: link.clicked() }
    FocusRing { anchors.margins: -4 }
  }

  // The studio, laid out as a canvas: the sections a carousel down the left,
  // the one on screen at its head beside the bar of its commands; the flow
  // fills the whole window under them, the other sections stand right of the
  // carousel over the canvas's dots.
  FloatingWindow {
    id: window

    title: "omunculus · studio"
    implicitWidth: Math.min(1600, screen ? screen.width - 96 : 1600)
    implicitHeight: Math.min(980, screen ? screen.height - 96 : 980)
    minimumSize: Qt.size(720, 480)
    color: Theme.background

    onClosed: Qt.quit()

    // 0 is the flow; then the sections of the settings, in their order.
    property int page: 0
    readonly property var sections: [
      { name: "flow" },
      { name: "secrets" },
      { name: "models" },
      { name: "agents" },
      { name: "workflows" },
      { name: "tools" },
      { name: "skills" },
      { name: "project" }
    ]
    // What can be added, each in its section, which it opens.
    function adding(text, page, section) {
      return { text: "ADD " + text, short: text, icon: "plus", run: () => { window.page = page; settings.create(section) } }
    }
    // The flow's commands: everything the project can be given. The other
    // sections' come from what is picked or open in them.
    readonly property var commands: page === 0
      ? [adding("AGENT", 3, "agents"), adding("WORKFLOW", 4, "workflows"), adding("MODEL", 2, "models"), adding("PROVIDER", 1, "auth"), adding("WORKSPACE", 7, "workspaces")]
      : settings.commands

    // Chooses a section and gives it the keyboard, so the carousel folds
    // away and the arrows reach what is on screen.
    function choose(index) {
      page = (index + sections.length) % sections.length
      rail.pinned = false
      Qt.callLater(() => page === 0 ? flow.forceActiveFocus() : settings.takeFocus())
    }

    Item {
      anchors.fill: parent
      focus: true

      // The flow's keys, wherever the keyboard is while it shows.
      Shortcut { enabled: window.page === 0; sequence: "F"; onActivated: flow.fit() }
      Shortcut { enabled: window.page === 0; sequence: "0"; onActivated: flow.actualSize() }
      Shortcut { enabled: window.page === 0; sequences: ["+", "="]; onActivated: flow.zoomIn() }
      Shortcut { enabled: window.page === 0; sequence: "-"; onActivated: flow.zoomOut() }
      Shortcut { enabled: window.page === 0 && flow.pickedId !== ""; sequence: "Esc"; onActivated: flow.pickedId = "" }

      FlowView {
        id: flow
        anchors.fill: parent
        visible: window.page === 0
        leftInset: rail.x + rail.foldedWidth
        topInset: bar.y + bar.height
        bottomInset: footer.height
        onAgentPicked: name => settings.reveal("agents", name)
      }

      // Behind the other sections, the canvas's dots stand still.
      Canvas {
        anchors.fill: parent
        visible: window.page !== 0
        onPaint: {
          const context = getContext("2d")
          context.reset()
          context.fillStyle = String(Qt.alpha(Theme.foreground, 0.07))
          for (let x = 14; x < width; x += 28)
            for (let y = 14; y < height; y += 28)
              context.fillRect(x, y, 1, 1)
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
      }

      Rectangle {
        anchors { left: parent.left; leftMargin: rail.x + rail.foldedWidth + 16; right: parent.right; rightMargin: 20; top: bar.bottom; topMargin: 16; bottom: footer.top; bottomMargin: 12 }
        visible: window.page !== 0
        color: Qt.alpha(Theme.background, 0.92)
        border.color: Theme.line

        SettingsView {
          id: settings
          anchors { fill: parent; margins: 20 }
          active: window.page !== 0
          page: Math.max(0, window.page - 1)
          onWanted: index => window.page = index + 1
        }
      }

      TabRail {
        id: rail
        x: 20
        y: 20
        // Over the bar and the canvas while it unfolds.
        z: 1
        tabs: window.sections
        current: window.page
        onChosen: index => window.choose(index)
      }

      CommandBar {
        id: bar
        anchors { left: parent.left; leftMargin: rail.x + rail.foldedWidth + 16; right: parent.right; rightMargin: 20 }
        y: 20
        height: rail.headHeight
        commands: window.commands
        section: window.page
        title: window.sections[window.page].name
      }

      // The footer: the studio, and the project the flow draws; with several
      // in the registry, each is named and picking one draws it. The
      // sections end above it.
      Rectangle {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 52
        // Over the flow, it hides what runs under it.
        color: window.page === 0 ? Theme.background : "transparent"
        Row {
          anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
          spacing: 14
          Label { anchors.verticalCenter: parent.verticalCenter; text: "OMUNCULUS"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 5 }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "/"; color: Theme.primary; font.pixelSize: 10 }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "STUDIO"; color: Theme.secondary; font.pixelSize: 10; font.letterSpacing: 4 }
          Repeater {
            model: Studio.projects.length > 0 ? Studio.projects.map(project => project.id) : [Studio.project]
            delegate: Link {
              id: projectName
              required property string modelData
              anchors.verticalCenter: parent.verticalCenter
              value: modelData.toUpperCase()
              current: modelData === flow.projectId
              onClicked: { flow.projectId = projectName.modelData; window.page = 0 }
            }
          }
        }
      }

      // How near the canvas is, and the ways to bring it nearer, farther, to
      // its actual size (pressing the number) or all in view.
      Rectangle {
        anchors { right: parent.right; rightMargin: 20; verticalCenter: footer.verticalCenter }
        visible: window.page === 0
        width: zoomRow.implicitWidth
        height: 36
        color: Qt.alpha(Theme.background, 0.94)
        border.color: Theme.line
        Row {
          id: zoomRow
          height: parent.height
          Glyph { name: "chevron-down"; onClicked: flow.zoomOut() }
          Item {
            id: actual
            width: 76
            height: parent.height
            activeFocusOnTab: true
            Keys.onReturnPressed: flow.actualSize()
            Keys.onSpacePressed: flow.actualSize()
            DecodeLabel {
              anchors.centerIn: parent
              value: Math.round(flow.zoomLevel * 100) + " %"
              autoPlay: false
              color: zoomPointer.containsMouse || actual.activeFocus ? Theme.primary : Theme.foreground
              font.pixelSize: 12
              font.letterSpacing: 2
            }
            MouseArea { id: zoomPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: flow.actualSize() }
            FocusRing {}
          }
          Glyph { name: "chevron-up"; onClicked: flow.zoomIn() }
          Glyph { name: "map"; onClicked: flow.fit() }
        }
      }

      // Ctrl+1 to Ctrl+8 choose a section; Ctrl+Tab and Ctrl+Shift+Tab turn the carousel.
      Repeater {
        model: window.sections.length
        delegate: Item {
          required property int index
          Shortcut { sequence: "Ctrl+" + (index + 1); onActivated: window.choose(index) }
        }
      }
      Shortcut { sequence: "Ctrl+Tab"; onActivated: window.choose(window.page + 1) }
      Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: window.choose(window.page - 1) }
      Shortcut { sequence: "Ctrl+Backtab"; onActivated: window.choose(window.page - 1) }
    }
  }
}
