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

  // A figure's name, set apart from the one above when stacked, and its value.
  component Name: Label {
    Layout.topMargin: parent && parent.columns === 1 ? 6 : 0
    color: Theme.dim
    font.pixelSize: 11
  }
  component Value: Label {
    Layout.fillWidth: true
    font.pixelSize: 11
    wrapMode: Text.Wrap
  }

  // Each figure's name beside its value, or above it under 480 px.
  component Figures: GridLayout {
    id: figures
    required property var used
    columns: width < 480 ? 1 : 2
    columnSpacing: 14
    rowSpacing: columns === 1 ? 2 : 6
    Name { text: "model calls" }
    Value { text: String(figures.used.calls) }
    Name { text: "read by the model" }
    Value { text: view.tokens(figures.used.input) + (figures.used.cached > 0 ? "  ·  (" + view.tokens(figures.used.cached) + " from cache)" : "") }
    Name { text: "written by the model" }
    Value { text: view.tokens(figures.used.output) }
    Name { text: "cost" }
    Value {
      text: figures.used.priced === 0 ? "-" : Omunculus.money(figures.used.cost)
        + (figures.used.priced < figures.used.calls ? "  ·  " + figures.used.priced + " of " + figures.used.calls + " calls priced" : "")
      color: figures.used.priced === 0 ? Theme.dim : Theme.primary
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
        wrapMode: Text.Wrap
      }
    }
  }
}
