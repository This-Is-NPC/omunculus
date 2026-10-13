import QtQuick
import Quickshell
import "kit/ui"

ShellRoot {
  // An icon pressed on its own, without a frame, as the zoom's are.
  component Glyph: Item {
    id: glyph
    property string name
    signal clicked()
    width: 32
    height: 32
    Icon {
      anchors.centerIn: parent
      name: glyph.name
      size: 12
      color: pointer.containsMouse ? Theme.primary : Theme.dim
      Behavior on color { ColorAnimation { duration: 150 } }
    }
    MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: glyph.clicked() }
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
    readonly property var adds: ({
      provider: { text: "ADD PROVIDER", short: "PROVIDER", icon: "plus", run: () => { window.page = 1; settings.add("auth", "provider") } },
      model: { text: "ADD MODEL", short: "MODEL", icon: "plus", run: () => { window.page = 2; settings.add("models", "model") } },
      agent: { text: "ADD AGENT", short: "AGENT", icon: "plus", run: () => { window.page = 3; settings.agent = settings.add("agents", "agent") } },
      workflow: { text: "ADD WORKFLOW", short: "WORKFLOW", icon: "plus", run: () => { window.page = 4; settings.add("workflows", "workflow") } },
      workspace: { text: "ADD WORKSPACE", short: "WORKSPACE", icon: "plus", run: () => { window.page = 7; settings.add("workspaces", "workspace") } }
    })
    // Each section's commands, as the command bar shows them; the flow's are
    // everything the project can be given.
    readonly property var commands: [
      [adds.agent, adds.workflow, adds.model, adds.provider, adds.workspace],
      [adds.provider],
      [adds.model],
      [adds.agent],
      [adds.workflow],
      [],
      [],
      [adds.workspace]
    ]

    function choose(index) { page = (index + sections.length) % sections.length }

    Item {
      anchors.fill: parent
      focus: true

      Keys.onPressed: event => {
        if (window.page !== 0 || event.modifiers & Qt.ControlModifier)
          return
        const run = {
          [Qt.Key_F]: () => flow.fit(), [Qt.Key_0]: () => flow.actualSize(),
          [Qt.Key_Plus]: () => flow.zoomIn(), [Qt.Key_Equal]: () => flow.zoomIn(), [Qt.Key_Minus]: () => flow.zoomOut()
        }[event.key]
        if (run) {
          run()
          event.accepted = true
        }
      }

      FlowView {
        id: flow
        anchors.fill: parent
        visible: window.page === 0
        leftInset: rail.x + rail.foldedWidth
        topInset: bar.y + bar.height
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
        anchors { left: parent.left; leftMargin: rail.x + rail.foldedWidth + 20; right: parent.right; rightMargin: 20; top: bar.bottom; topMargin: 16; bottom: parent.bottom; bottomMargin: 20 }
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
        commands: window.commands[window.page]
        section: window.page
      }

      // The studio, and the project the flow draws: with several in the
      // registry, each is named and picking one draws it.
      Rectangle {
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 14; bottomMargin: 12 }
        width: brand.implicitWidth + 12
        height: brand.implicitHeight + 12
        color: Theme.background
      }
      Row {
        id: brand
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 20; bottomMargin: 18 }
        spacing: 10
        Label { text: "OMUNCULUS"; color: Theme.dim; font.pixelSize: 10; font.letterSpacing: 5 }
        Label { text: "/"; color: Theme.primary; font.pixelSize: 10 }
        Label { text: "STUDIO"; color: Theme.secondary; font.pixelSize: 10; font.letterSpacing: 4 }
        Repeater {
          model: Studio.projects.length > 0 ? Studio.projects.map(project => project.id) : [Studio.project]
          delegate: DecodeLabel {
            id: projectName
            required property string modelData
            value: modelData.toUpperCase()
            color: modelData === flow.projectId ? Theme.primary : projectPointer.containsMouse ? Theme.foreground : Theme.dim
            font.pixelSize: 10
            font.letterSpacing: 4
            MouseArea { id: projectPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { flow.projectId = projectName.modelData; window.page = 0 } }
          }
        }
      }

      // How near the canvas is, and the ways to bring it nearer, farther, to
      // its actual size (pressing the number) or all in view.
      Rectangle {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 20; bottomMargin: 20 }
        visible: window.page === 0
        width: zoomRow.implicitWidth
        height: 32
        color: Qt.alpha(Theme.background, 0.94)
        border.color: Theme.line
        Row {
          id: zoomRow
          height: parent.height
          Glyph { name: "chevron-down"; onClicked: flow.zoomOut() }
          Item {
            width: 76
            height: parent.height
            DecodeLabel {
              anchors.centerIn: parent
              value: Math.round(flow.zoomLevel * 100) + " %"
              autoPlay: false
              color: zoomPointer.containsMouse ? Theme.primary : Theme.foreground
              font.pixelSize: 12
              font.letterSpacing: 2
            }
            MouseArea { id: zoomPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: flow.actualSize() }
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
