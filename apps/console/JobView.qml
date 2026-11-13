pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Jobs.js" as Jobs
import "kit/client/Requests.js" as Requests
import "kit/client/Time.js" as Time
import "kit/ui/Breakpoints.js" as Breakpoints
import "kit/ui"

// JobView is one job on a page of its own: its name, state and schedule in
// words on top; under them its next and last fire and its totals — fires,
// success, cost, calls, tokens and time; and its tabs: FIRES, each fire's
// state, duration, calls, tokens and cost, which opens the conversation it
// made; VERSIONS, who changed it and through which channel, and each move
// between states with its reason; and FIELDS, everything the job holds. The
// actions — pause or resume, run now, edit, duplicate, archive — are the bar's,
// which PagesView gives. The job and its history are read again every few
// seconds while the page is on screen. Esc leaves.
FocusScope {
  id: view

  required property string key
  property bool active: false
  signal leave()
  // The conversation a fire made, by its id.
  signal openConversation(string id)

  readonly property var job: Omunculus.jobs.find(key)
  // The job's history events, oldest first.
  property var events: []
  readonly property var fires: Jobs.fires(events)
  readonly property var changes: Jobs.changes(events)
  readonly property var totals: job ? job.fires : null
  readonly property bool stacked: Breakpoints.size(width) === "narrow"

  property real now: Date.now()
  property string section: "fires"
  readonly property var sections: ["fires", "versions", "fields"]

  function reload() {
    if (job)
      Omunculus.jobs.history(job.id, found => view.events = found)
  }
  onKeyChanged: {
    events = []
    section = "fires"
    Qt.callLater(reload)
  }
  // The history is read again when what the list says of the job changes.
  readonly property string stamp: job ? job.version + job.state + (job.fires ? job.fires.fires : "") + (job.next_fire || "") : ""
  onStampChanged: reload()
  Timer {
    interval: 10000
    repeat: true
    running: view.active && Omunculus.connected
    onTriggered: {
      view.now = Date.now()
      Omunculus.jobs.load()
    }
  }

  Keys.onEscapePressed: leave()

  // The lines of the FIELDS tab, as {name, value}.
  readonly property var fields: {
    if (!job)
      return []
    const conversation = job.conversation_id
    const lines = [
      ["RUNS", Jobs.target(job)],
      [job.tool ? "TOOL" : "MESSAGE", job.tool ? job.tool : job.message || ""],
      ["SCHEDULE", Jobs.when(job.schedule) + "  ·  " + job.timezone],
      ["CONVERSATION", conversation ? (Omunculus.summaries[conversation] || {}).title || conversation : "a new one each fire"],
      ["WORKSPACE", job.workspace || ""],
      ["CONDITION", job.condition ? job.condition + " must pass before each fire" : ""],
      ["ENDS", job.end_at ? Time.full(job.end_at).slice(0, 17) : ""],
      ["OWNER", job.owner ? Requests.label(job.owner) : ""],
      ["DELIVERY", job.delivery === "owner_inbox" ? "each reply to the owner's inbox" : "none"],
      ["ORIGIN", Jobs.origin(job)],
      ["VERSION", String(job.version)],
      ["CREATED", Time.began(job.created_at, now)],
      ["STATE", job.state_reason ? Jobs.mark(job.state).word.toLowerCase() + ": " + job.state_reason : ""]
    ]
    return lines.filter(line => line[1] !== "").map(line => ({ name: line[0], value: line[1] }))
  }

  // A figure of the header: its name over its value.
  component Figure: ColumnLayout {
    id: figure
    property string name
    property string value
    spacing: Theme.space.line
    Caption { text: figure.name }
    Label {
      text: figure.value
      font.pixelSize: Theme.type.body.size
      color: Theme.foreground
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Theme.space.block
    visible: view.job !== null

    // Its name and its state, and what it runs when.
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Theme.space.tight
      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.gap
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          text: view.job ? view.job.name : ""
          font.pixelSize: Theme.type.input.size
          font.bold: true
          elide: Text.ElideRight
        }
        Icon {
          Layout.alignment: Qt.AlignVCenter
          name: view.job ? Jobs.mark(view.job.state).icon : "more"
          size: 12
          color: view.job ? Theme[Jobs.mark(view.job.state).tone] : Theme.dim
        }
        Label {
          Layout.alignment: Qt.AlignVCenter
          text: view.job ? Jobs.mark(view.job.state).word : ""
          color: view.job ? Theme[Jobs.mark(view.job.state).tone] : Theme.dim
          font.pixelSize: Theme.type.meta.size
          font.letterSpacing: Theme.type.meta.tracking
        }
      }
      Label {
        Layout.fillWidth: true
        text: view.job ? Jobs.when(view.job.schedule) + "  ·  " + view.job.timezone + "  ·  " + Jobs.target(view.job) : ""
        color: Theme.dim
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
      }
      Label {
        Layout.fillWidth: true
        visible: !!view.job && !!view.job.state_reason
        text: view.job && view.job.state_reason ? view.job.state_reason : ""
        color: Theme.warning
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
      }
    }

    Flow {
      Layout.fillWidth: true
      spacing: Theme.space.section
      Figure { name: "NEXT FIRE"; value: view.job ? Jobs.at(view.job.next_fire, view.now) : "" }
      Figure { name: "LAST FIRE"; value: view.job ? Jobs.last(view.job, view.now) : "" }
      Figure { name: "FIRES"; value: view.totals ? Jobs.count(view.totals.fires) + " (" + Jobs.count(view.totals.succeeded) + " ok, " + Jobs.count(view.totals.failed) + " failed, " + Jobs.count(view.totals.skipped) + " skipped)" : "" }
      Figure { name: "SUCCESS"; value: Jobs.rate(view.totals) }
      Figure { name: "COST"; value: view.totals ? Jobs.cost(view.totals.usd) : "" }
      Figure { name: "CALLS"; value: view.totals ? Jobs.count(view.totals.calls) : "" }
      Figure { name: "TOKENS"; value: view.totals ? Jobs.tokens(view.totals.input_tokens + view.totals.output_tokens) : "" }
      Figure { name: "TIME"; value: view.totals ? Jobs.took(view.totals.duration_ms) : "" }
    }

    Flickable {
      id: tabStrip
      Layout.fillWidth: true
      Layout.preferredHeight: tabRow.height
      contentWidth: tabRow.width
      contentHeight: tabRow.height
      clip: true
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds
      Row {
        id: tabRow
        spacing: Theme.space.section
        Repeater {
          model: view.sections
          delegate: Tab {
            required property string modelData
            required property int index
            label: modelData
            digit: Breakpoints.tight(view.width) ? "" : String(index + 1).padStart(2, "0")
            current: view.section === modelData
            onChosen: view.section = modelData
          }
        }
      }
    }

    // What is under the tab chosen.
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      DataTable {
        anchors.fill: parent
        visible: view.section === "fires"
        active: visible && view.active
        rows: view.fires
        columns: [
          { title: "scheduled", weight: 0.2 }, { title: "state", weight: 0.14 }, { title: "took", weight: 0.1 },
          { title: "calls", weight: 0.08 }, { title: "tokens", weight: 0.09 }, { title: "cost", weight: 0.1 },
          { title: "version", weight: 0.08 }, { title: "note", weight: 0.21 }
        ]
        cells: fire => {
          const note = [[fire.manual ? "run now" : "", fire.reason].filter(text => text !== "").join(": "), fire.conversation !== "" ? "conversation \u203a" : ""].filter(text => text !== "").join("  \u00b7  ")
          return [Jobs.at(fire.when, view.now), Jobs.mark(fire.state).word, Jobs.took(fire.took), Jobs.count(fire.calls) + (compact ? (fire.calls === 1 ? " call" : " calls") : ""),
            Jobs.tokens(fire.tokens) + (compact ? " tokens" : ""), Jobs.cost(fire.usd), "v" + fire.version, note]
        }
        tone: (fire, column) => column === 1 ? Theme[Jobs.mark(fire.state).tone] : ""
        statusIcon: fire => Jobs.mark(fire.state).icon
        stacked: [[0], [2, 3], [4, 5], [7]]
        status: 1
        tip: fire => fire.conversation !== "" ? "open the conversation this fire made" : ""
        emptyText: view.events.length === 0 ? "reading the fires" : "no fire yet"
        onOpened: fire => {
          if (fire.conversation !== "")
            view.openConversation(fire.conversation)
        }
        onBackRequested: view.leave()
      }

      DataTable {
        anchors.fill: parent
        visible: view.section === "versions"
        active: visible && view.active
        rows: view.changes.map((change, at) => Object.assign({ id: String(at) }, change))
        columns: [
          { title: "version", weight: 0.09 }, { title: "when", weight: 0.17 }, { title: "by", weight: 0.17 },
          { title: "channel", weight: 0.12 }, { title: "what", weight: 0.45 }
        ]
        cells: change => [change.version > 0 ? "v" + change.version : "", Jobs.at(change.at, view.now), change.author, change.channel, change.text]
        stacked: [[4], [0, 1], [2, 3]]
        emptyText: "no change yet"
        onBackRequested: view.leave()
      }

      ScrollPage {
        id: fieldsPage
        anchors.fill: parent
        visible: view.section === "fields"
        contentWidth: width
        contentHeight: fieldList.implicitHeight
        ColumnLayout {
          id: fieldList
          width: fieldsPage.width
          spacing: Theme.space.gap
          Repeater {
            model: view.fields
            delegate: RowLayout {
              id: row
              required property var modelData
              Layout.fillWidth: true
              spacing: Theme.space.gap
              Caption { Layout.preferredWidth: Theme.size.measureFrom / 4; Layout.alignment: Qt.AlignTop; text: row.modelData.name }
              Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: row.modelData.value
                font.pixelSize: Theme.type.body.size
                wrapMode: Text.Wrap
              }
            }
          }
        }
      }
    }
  }

  Label {
    anchors.centerIn: parent
    visible: view.job === null
    text: Omunculus.jobs.loaded ? "this job is gone" : "reading the job"
    color: Theme.dim
  }
}
