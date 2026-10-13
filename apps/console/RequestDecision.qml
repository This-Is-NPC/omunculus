pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// RequestDecision is one request, wherever it shows: who asked, on which work,
// what for and what that lets it do, and who decides — you, or the agent above,
// whom you can always overrule. While it waits, the answers come grouped: for
// this work only, always (each scope saying where it is written), or no, with a
// reason. Answered, it says what was chosen and by whom.
SurfaceFrame {
  id: card

  required property string key
  property string stamp: ""

  readonly property var request: Omunculus.requests.find(item => item.id === key) || null
  readonly property var answer: Omunculus.replies[key] || null
  readonly property bool open: request !== null && String(request.status).startsWith("waiting")
  readonly property bool yours: open && request.arbiter === "human"
  readonly property var work: request ? Omunculus.work(request.work_id || "") : null
  readonly property string asker: request ? request.agent || "" : ""
  readonly property var options: request ? Object.keys(request.options || {}) : []
  // The first name a grant of the request gives, as {kind, name}.
  readonly property var wanted: {
    for (const option of options)
      for (const step of request.options[option])
        if (step.name === "grant")
          return step.args
    return null
  }
  readonly property var depth: {
    const configured = Omunculus.setup ? Omunculus.setup.agents.find(item => item.name === asker) : null
    return configured ? configured.depth : null
  }
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")

  // What the granted name lets the agent do.
  function unlocks(granted) {
    if (!granted)
      return ""
    if (granted.kind === "resource")
      return { "sandbox.write": "write files in " + (place.root || "its workspace"), "sandbox.network": "use the network" }[granted.name] || "use " + granted.name
    if (granted.kind === "tool")
      return "call the tool " + granted.name
    return "reach " + granted.name
  }

  // How an option reads on its button.
  function labelOf(option) {
    return ({
      grant: "THIS WORK ONLY",
      grant_agent: "FOR " + asker.toUpperCase(),
      grant_depth: depth === null ? "AT ITS DEPTH" : "AT DEPTH " + depth,
      grant_stage: "IN STAGE " + String(work && work.stage ? work.stage : "").toUpperCase(),
      grant_workspace: "IN " + (place.name ? "WORKSPACE " + place.name.toUpperCase() : "THE PROJECT"),
      deny: "DENY"
    })[option] || option.replace(/_/g, " ").toUpperCase()
  }

  readonly property var always: options.filter(option => option.startsWith("grant_"))
  readonly property var others: options.filter(option => option !== "grant" && option !== "deny" && !option.startsWith("grant_"))

  implicitHeight: content.implicitHeight + 24
  variant: yours ? "filled" : "outline"
  tone: Theme.warning
  active: yours

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14; rightMargin: 14 }
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Icon { Layout.alignment: Qt.AlignVCenter; name: "warning"; size: 11; color: card.open ? Theme.warning : Theme.dim }
      Label { Layout.alignment: Qt.AlignVCenter; text: card.asker.toUpperCase(); color: Omunculus.toneOf(card.asker); font.pixelSize: 10; font.letterSpacing: 3 }
      Label {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        text: card.work ? card.work.title : ""
        color: Theme.dim
        font.pixelSize: 10
        elide: Text.ElideRight
      }
      Label { Layout.alignment: Qt.AlignVCenter; text: card.stamp; color: Theme.line; font.pixelSize: 9; font.letterSpacing: 1 }
    }

    Label {
      Layout.fillWidth: true
      visible: card.wanted !== null
      text: "asks for " + (card.wanted ? card.wanted.name : "") + "  —  to " + card.unlocks(card.wanted)
      color: Theme.foreground
      font.pixelSize: 13
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      visible: (Omunculus.reasons[card.key] || "") !== ""
      text: Omunculus.inline(Omunculus.reasons[card.key] || "")
      textFormat: Text.MarkdownText
      color: Theme.dim
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      text: !card.request ? ""
        : card.open ? (card.yours ? "YOU DECIDE" : String(card.request.arbiter).toUpperCase() + " DECIDES  ·  YOU CAN DECIDE INSTEAD")
        : card.answer ? card.labelOf(card.answer.option) + " — BY " + card.answer.who.toUpperCase() + (card.answer.body && card.answer.body !== card.answer.option ? ": " + card.answer.body : "")
        : "CLOSED"
      color: card.yours ? Theme.warning : Theme.dim
      font.pixelSize: 10
      font.letterSpacing: 2
      wrapMode: Text.Wrap
    }

    // For this work only.
    Flow {
      Layout.fillWidth: true
      visible: card.open && (card.options.includes("grant") || card.others.length > 0)
      spacing: 6
      TraceButton {
        visible: card.options.includes("grant")
        dense: true
        role: "primary"
        icon: "check"
        text: card.labelOf("grant")
        onClicked: Omunculus.reply(card.key, "grant", "")
      }
      Repeater {
        model: card.others
        delegate: TraceButton {
          required property string modelData
          dense: true
          role: "progress"
          text: card.labelOf(modelData)
          onClicked: Omunculus.reply(card.key, modelData, "")
        }
      }
    }

    // Always: each scope a grant written into the TOML.
    ColumnLayout {
      Layout.fillWidth: true
      visible: card.open && card.always.length > 0
      spacing: 6
      Caption { text: "ALWAYS  ·  WRITTEN INTO OMUNCULUS.TOML" }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        Repeater {
          model: card.always
          delegate: Chip {
            required property string modelData
            text: card.labelOf(modelData)
            onClicked: Omunculus.reply(card.key, modelData, "")
          }
        }
      }
    }

    // No, with a reason the agent reads.
    RowLayout {
      Layout.fillWidth: true
      visible: card.open && card.options.includes("deny")
      spacing: 8
      TextBox {
        id: reason
        Layout.fillWidth: true
        dense: true
        placeholderText: "why not, for the agent"
        onAccepted: Omunculus.reply(card.key, "deny", reason.text.trim())
      }
      TraceButton {
        dense: true
        role: "guarded"
        icon: "close"
        text: "DENY"
        onClicked: Omunculus.reply(card.key, "deny", reason.text.trim())
      }
    }
  }
}
