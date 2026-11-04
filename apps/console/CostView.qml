pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// CostView is what the conversation open has used: the model calls, the
// tokens read by the model (with those from cache) and written by it, and
// what they cost, in all and by agent, the busiest agent first. A cost shows
// only for calls whose provider reported one; one note says when none did.
// Esc leaves.
FocusScope {
  id: view

  signal leave()

  readonly property var agents: Object.keys(Omunculus.usage.agents).sort((a, b) => {
    const used = name => Omunculus.usage.agents[name].input + Omunculus.usage.agents[name].output
    return used(b) - used(a) || a.localeCompare(b)
  })
  readonly property bool unpriced: Omunculus.usage.all.calls > 0 && Omunculus.usage.all.priced === 0

  function tokens(count) {
    return count.toLocaleString(Qt.locale("en_US"), "f", 0)
  }

  Keys.onEscapePressed: leave()

  component Figures: GridLayout {
    id: figures
    required property var used
    columns: 2
    columnSpacing: 14
    rowSpacing: 6
    Label { text: "model calls"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: String(figures.used.calls); font.pixelSize: 11 }
    Label { text: "read by the model"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: view.tokens(figures.used.input) + (figures.used.cached > 0 ? "  ·  (" + view.tokens(figures.used.cached) + " from cache)" : ""); font.pixelSize: 11 }
    Label { text: "written by the model"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: view.tokens(figures.used.output); font.pixelSize: 11 }
    Label { text: "cost"; color: Theme.dim; font.pixelSize: 11 }
    Label {
      text: figures.used.priced === 0 ? "-" : Omunculus.money(figures.used.cost)
        + (figures.used.priced < figures.used.calls ? "  ·  " + figures.used.priced + " of " + figures.used.calls + " calls priced" : "")
      color: figures.used.priced === 0 ? Theme.dim : Theme.primary
      font.pixelSize: 11
    }
  }

  ScrollPage {
    id: scroll
    anchors.fill: parent
    contentHeight: form.implicitHeight

    ColumnLayout {
      id: form
      width: Math.min(scroll.width, 560)
      spacing: 18

      Kicker { Layout.fillWidth: true; text: "in all" }
      Figures { Layout.fillWidth: true; used: Omunculus.usage.all }

      Repeater {
        model: view.agents.length > 1 ? view.agents : []
        delegate: ColumnLayout {
          id: agent
          required property string modelData
          Layout.fillWidth: true
          spacing: 8
          Kicker { Layout.fillWidth: true; text: agent.modelData; tone: Omunculus.toneOf(agent.modelData) }
          Figures { Layout.fillWidth: true; used: Omunculus.usage.agents[agent.modelData] }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: view.unpriced
        text: "The provider sends no price."
        color: Theme.dim
        font.pixelSize: 11
      }
    }
  }
}
