pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// CostDialog is what the conversation on screen has used, opened from the bar
// of its conversation and map pages: the model calls, the tokens read, read from
// cache and written, and what they cost, in all and by agent. A cost shows
// only for calls whose provider reported one.
ModalDialog {
  id: dialog

  maxWidth: 560

  readonly property var agents: Object.keys(Omunculus.usage.agents).sort()

  function money(spent) {
    return "US$ " + (spent < 0.01 ? spent.toFixed(4) : spent.toFixed(2))
  }

  function tokens(count) {
    return count.toLocaleString(Qt.locale("en_US"), "f", 0)
  }

  component Figures: GridLayout {
    id: figures
    required property var used
    columns: 2
    columnSpacing: 14
    rowSpacing: 6
    Label { text: "model calls"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: String(figures.used.calls); font.pixelSize: 11 }
    Label { text: "tokens read"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: dialog.tokens(figures.used.input) + (figures.used.cached > 0 ? "  ·  " + dialog.tokens(figures.used.cached) + " from cache" : ""); font.pixelSize: 11 }
    Label { text: "tokens written"; color: Theme.dim; font.pixelSize: 11 }
    Label { text: dialog.tokens(figures.used.output); font.pixelSize: 11 }
    Label { text: "cost"; color: Theme.dim; font.pixelSize: 11 }
    Label {
      text: figures.used.priced === 0 ? "not reported" : dialog.money(figures.used.cost)
        + (figures.used.priced < figures.used.calls ? "  ·  " + figures.used.priced + " of " + figures.used.calls + " calls priced" : "")
      color: figures.used.priced === 0 ? Theme.dim : Theme.primary
      font.pixelSize: 11
    }
  }

  contentItem: DialogPanel {
    dialogOpen: dialog.visible
    implicitHeight: form.implicitHeight + 56
    index: "$"
    title: "cost"
    active: true

    ColumnLayout {
      id: form
      anchors.fill: parent
      spacing: 18

      Label {
        Layout.fillWidth: true
        text: Omunculus.title
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }

      Figures { Layout.fillWidth: true; used: Omunculus.usage.all }

      Repeater {
        model: dialog.agents.length > 1 ? dialog.agents : []
        delegate: ColumnLayout {
          id: agent
          required property string modelData
          Layout.fillWidth: true
          spacing: 8
          Kicker { Layout.fillWidth: true; text: agent.modelData; tone: Omunculus.toneOf(agent.modelData) }
          Figures { Layout.fillWidth: true; used: Omunculus.usage.agents[agent.modelData] }
        }
      }

      DialogFooter {
        cancelText: "CLOSE"
        onCancelled: dialog.close()
      }
    }
  }
}
