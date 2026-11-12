pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// UsageView is what the project's model replies used, as the providers
// reported it: the replies, the tokens read, read from cache and written, and
// the cost where a provider gave one, in all and for each agent with the
// model it runs on. The studio only reads it.
ItemPage {
  id: page

  required property Item settings

  readonly property var used: Studio.usage || { agents: [], total: { replies: 0, input: 0, cached: 0, output: 0, cost: 0 } }

  function tokens(count) {
    return count.toLocaleString(Qt.locale("en_US"), "f", 0)
  }

  function cost(totals) {
    return totals.cost > 0 ? "$" + totals.cost.toFixed(4) : "not reported"
  }

  function summary(totals) {
    return totals.replies + " replies  ·  " + tokens(totals.input) + " tokens read"
      + (totals.cached > 0 ? " (" + tokens(totals.cached) + " from cache)" : "")
      + "  ·  " + tokens(totals.output) + " written  ·  " + cost(totals)
  }

  related: [
    { title: "AGENTS", items: used.agents.map(entry => settings.link(2, entry.agent)) }
  ]

  kind: "usage"
  title: "usage"
  facts: [
    ["model replies", String(used.total.replies)],
    ["tokens read", tokens(used.total.input)],
    ["from cache", tokens(used.total.cached)],
    ["tokens written", tokens(used.total.output)],
    ["cost", cost(used.total)]
  ]
  details: [
    Note { value: "What every model reply recorded in the project used, by agent. A cost shows only for replies whose provider reported one." },
    Repeater {
      model: page.used.agents
      delegate: ColumnLayout {
        id: row
        required property var modelData
        Layout.fillWidth: true
        spacing: 4
        Kicker { Layout.fillWidth: true; text: row.modelData.agent + (row.modelData.models.length > 0 ? "  ·  " + row.modelData.models.join(", ") : ""); tone: Studio.toneOf(row.modelData.agent) }
        Label { Layout.fillWidth: true; text: page.summary(row.modelData); font.pixelSize: 11; wrapMode: Text.Wrap }
      }
    }
  ]
}
