import QtQuick
import Quickshell
import "kit/ui"

ShellRoot {
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
      { name: "flow", hint: "the project as it runs: depths, workflows, agents" },
      { name: "secrets", hint: "where each provider's key comes from" },
      { name: "models", hint: "the models the agents run on" },
      { name: "agents", hint: "who does what, on which model, with which tools" },
      { name: "workflows", hint: "the stages a work goes through" },
      { name: "tools", hint: "the catalog: builtin, the project's, MCP" },
      { name: "skills", hint: "what each agent knows how to do" },
      { name: "project", hint: "policy, workspaces and access" }
    ]
    // Each section's commands, as the command bar shows them.
    readonly property var commands: [
      [
        { text: "FIT", icon: "map", tip: "the whole flow in view  f", run: () => flow.fit() },
        { text: "100%", tip: "actual size  0", run: () => flow.actualSize() },
        { text: "", icon: "chevron-down", tip: "zoom out  -", run: () => flow.zoomOut() },
        { text: "", icon: "chevron-up", tip: "zoom in  +", run: () => flow.zoomIn() },
        { text: "READ AGAIN", icon: "spark", tip: "read every project again", run: () => Studio.loadOverviews() }
      ].concat(Studio.projects.length > 1 ? Studio.projects.map(project => ({
        text: project.id.toUpperCase(), icon: "folder", role: project.id === flow.projectId ? "primary" : "progress",
        tip: "draw " + project.id, run: () => flow.projectId = project.id
      })) : []),
      [{ text: "ADD PROVIDER", icon: "plus", run: () => settings.add("auth", "provider") }],
      [{ text: "ADD MODEL", icon: "plus", run: () => settings.add("models", "model") }],
      [{ text: "ADD AGENT", icon: "plus", run: () => settings.agent = settings.add("agents", "agent") }],
      [{ text: "ADD WORKFLOW", icon: "plus", run: () => settings.add("workflows", "workflow") }],
      [],
      [],
      [{ text: "ADD WORKSPACE", icon: "plus", run: () => settings.add("workspaces", "workspace") }]
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
        leftInset: rail.x + rail.width
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
        anchors { left: rail.right; leftMargin: 20; right: parent.right; rightMargin: 20; top: bar.bottom; topMargin: 16; bottom: parent.bottom; bottomMargin: 20 }
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
        width: 260
        height: parent.height - 40
        tabs: window.sections
        current: window.page
        onChosen: index => window.choose(index)
      }

      CommandBar {
        id: bar
        anchors { left: rail.right; leftMargin: 16; right: parent.right; rightMargin: 20 }
        y: 20
        height: rail.headHeight
        commands: window.commands[window.page]
        section: window.page
      }

      // The studio and the project it was opened on, in the corner.
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
        DecodeLabel { value: "STUDIO · " + Studio.project.toUpperCase(); color: Theme.secondary; font.pixelSize: 10; font.letterSpacing: 4 }
      }

      // How near the canvas is; pressing it brings it to its actual size.
      Rectangle {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 20; bottomMargin: 20 }
        visible: window.page === 0
        width: 120
        height: 32
        color: Qt.alpha(Theme.background, 0.9)
        border.color: zoomPointer.containsMouse ? Theme.primary : Theme.line
        DecodeLabel {
          anchors.centerIn: parent
          value: Math.round(flow.zoomLevel * 100) + " %"
          autoPlay: false
          color: Theme.foreground
          font.pixelSize: 12
          font.letterSpacing: 2
        }
        MouseArea { id: zoomPointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: flow.actualSize() }
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
