pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkPrompt is the prompt a run of the work picked on the map was given, as
// the prompt command prints it: of the run opened among its runs, else of
// its last one. It scrolls, and COPY puts it on the clipboard. A run with no
// assembled prompt says so.
Item {
  id: section

  // The work, or "" for the root agent's own conversation.
  required property string key
  // The run asked for, or "" for the work's last.
  property string run: ""
  signal latestWanted()

  readonly property var last: Omunculus.runs
    .filter(each => (each.work_id || "") === key)
    .sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)))[0] || null
  readonly property string shown: run !== "" ? run : last ? last.id : ""
  readonly property bool latest: last !== null && shown === last.id
  readonly property var shownRun: Omunculus.runs.find(each => each.id === shown) || null

  property string output: ""
  property string failure: ""
  property bool loading: false
  property int asked: 0

  function load() {
    output = ""
    failure = ""
    if (shown === "")
      return
    const token = ++asked
    loading = true
    Omunculus.cli(["prompt", "--run", shown], text => {
      if (token !== asked)
        return
      loading = false
      output = text
    }, reason => {
      if (token !== asked)
        return
      loading = false
      failure = reason
    })
  }

  onVisibleChanged: if (visible) load()
  onShownChanged: if (visible) load()

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.fillWidth: true
        text: section.shownRun
          ? (section.latest ? "LAST RUN  ·  " : "RUN  ·  ") + section.shown.slice(0, 8).toUpperCase()
            + "  ·  " + String(section.shownRun.agent).toUpperCase() + "  ·  " + String(section.shownRun.started_at || "").slice(5, 16).replace("T", " ")
          : ""
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 1
        elide: Text.ElideRight
      }
      TraceButton {
        dense: true
        role: "action"
        visible: !section.latest
        text: "LAST RUN"
        tip: "the prompt of the work's last run"
        onClicked: section.latestWanted()
      }
      IconButton { name: "copy"; tip: "copy the prompt"; visible: section.output !== ""; onClicked: Omunculus.copy(section.output) }
    }

    Label {
      Layout.fillWidth: true
      visible: section.output === ""
      text: section.shown === "" ? "NO RUN OF THIS WORK YET"
        : section.failure !== "" ? section.failure
        : section.loading ? "READING THE PROMPT"
        : ""
      color: section.failure !== "" ? Theme.warning : Theme.dim
      font.pixelSize: section.failure !== "" ? 11 : 10
      font.letterSpacing: section.failure !== "" ? 0 : 2
      wrapMode: Text.Wrap
    }

    TextPane {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: section.output !== ""
      text: section.output
      tone: line => /^#+ /.test(line) ? Theme.primary : Theme.foreground
    }

    Item { Layout.fillHeight: true; visible: section.output === "" }
  }
}
