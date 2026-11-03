pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkChanges is the files the work picked on the map changed, call by call,
// as the changes command lists them from what [store] changes recorded:
// each call, and under it each file with what was done to it — added,
// modified or deleted — and its lines. DIFF shows the unified diff instead,
// its added and removed lines coloured. REVERT, for a member holding
// project.manage_config, puts the files back after a confirmation, in the
// workspace the work ran in. Why there is nothing to show — the
// project records no changes, or no call changed a file — reads as text.
Item {
  id: section

  // The work, or "" for the root agent's own conversation.
  required property string key
  property bool patch: false

  // Its runs that have closed, to read again when one does.
  readonly property string closed: Omunculus.runs
    .filter(run => (run.work_id || "") === key && run.status !== "open")
    .map(run => run.id).join(" ")

  property string output: ""
  property string failure: ""
  property bool loading: false
  property int asked: 0

  function load() {
    if (key === "")
      return
    const token = ++asked
    loading = true
    Omunculus.command("changes", { work_id: key, patch: patch }, text => {
      if (token !== asked)
        return
      loading = false
      failure = ""
      output = text
    }, reason => {
      if (token !== asked)
        return
      loading = false
      output = ""
      failure = reason
    })
  }

  // A line of what is shown, by where it is among `lines`: a call's heading,
  // a file it changed, or a line of its diff.
  readonly property var lines: output.split("\n")
  function lineTone(line, index) {
    if (line.startsWith("- ") && (index === 0 || !patch || (lines[index + 1] || "").startsWith("diff ")))
      return Theme.dim
    if (patch) {
      if (/^(\+\+\+ |--- |diff |index |new file|deleted file|old mode|new mode|similarity|rename |Binary )/.test(line))
        return Theme.dim
      if (line.startsWith("@@"))
        return Theme.secondary
      return line.startsWith("+") ? Theme.success : line.startsWith("-") ? Theme.error : Theme.foreground
    }
    return { A: Theme.success, D: Theme.error }[line.trim().charAt(0)] || Theme.foreground
  }

  readonly property bool canRevert: Omunculus.capabilities.includes("project.manage_config")

  onVisibleChanged: if (visible) load()
  onKeyChanged: {
    output = ""
    failure = ""
    if (visible)
      load()
  }
  onPatchChanged: load()
  onClosedChanged: if (visible) load()

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Label {
        Layout.fillWidth: true
        text: section.patch ? "THE DIFF, CALL BY CALL" : "THE FILES, CALL BY CALL"
        color: Theme.dim
        font.pixelSize: 10
        font.letterSpacing: 2
        elide: Text.ElideRight
      }
      TraceButton {
        dense: true
        role: "action"
        enabled: section.key !== "" && section.failure === ""
        text: section.patch ? "FILES" : "DIFF"
        tip: section.patch ? "the files each call changed" : "the unified diff of each call"
        onClicked: section.patch = !section.patch
      }
      TraceButton {
        dense: true
        role: "guarded"
        icon: "close"
        visible: section.canRevert
        enabled: section.key !== "" && section.failure === "" && section.output !== "" && !section.output.startsWith("No call changed")
        text: "REVERT"
        tip: "put the files of this work back as they were before it"
        onClicked: confirmRevert.open()
      }
      IconButton { name: "copy"; tip: "copy what is shown"; visible: section.output !== ""; onClicked: Omunculus.copy(section.output) }
    }

    Label {
      Layout.fillWidth: true
      visible: section.output === ""
      text: section.key === "" ? "CHANGES ARE KEPT BY WORK; THIS IS THE ROOT AGENT'S OWN CONVERSATION"
        : section.failure !== "" ? section.failure
        : section.loading ? "READING THE CHANGES"
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
      tone: (line, index) => section.lineTone(line, index)
    }

    Item { Layout.fillHeight: true; visible: section.output === "" }
  }

  ConfirmDialog {
    id: confirmRevert
    title: "revert the work"
    question: "Put back the files this work changed, as they were before it, in the workspace it ran in? Files it added are removed."
    warning: "Refused, restoring nothing, when a file changed since the work's last change to it."
    confirmText: "REVERT"
    onConfirmed: Omunculus.revert(section.key, () => section.load())
  }
}
