pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"

// TeamPanel is who works on the conversation, as a tree: the stage the root
// work is at, then a row per work, indented by level — state icon and word,
// agent, task, what it is doing and for how long — each team foldable.
// A row that finished stays for 30 s and then folds into its parent's (+N);
// a failed one stays. Picking a row shows its details under the tree: its
// latest words, what it asked and still waits for, and the way to its log.
// `activity` is Activity.status's result; the panel draws it, it keeps none.
Item {
  id: panel

  property var activity: null
  signal openLog(string work)

  readonly property var rows: activity && activity.rows ? activity.rows : []
  readonly property var stage: activity && activity.stage && activity.stage.name ? activity.stage : null
  // The work picked, "" for none, and the teams folded, by work id.
  property string picked: ""
  property var folded: ({})
  property real now: Date.now()
  readonly property int settle: 30000

  Timer {
    interval: 1000
    repeat: true
    running: panel.visible && panel.rows.length > 0
    onTriggered: panel.now = Date.now()
  }

  // The state's icon, word and tone: the vocabulary of the whole window.
  readonly property var looks: ({
    "working": { icon: "spark", word: "WORKING", tone: Theme.primary },
    "waiting-you": { icon: "warning", word: "WAITING FOR YOU", tone: Theme.warning },
    "waiting-team": { icon: "people", word: "WAITING FOR THE TEAM", tone: Theme.dim },
    "done": { icon: "check", word: "DONE", tone: Theme.success },
    "failed": { icon: "close", word: "FAILED", tone: Theme.error },
    "idle": { icon: "more", word: "IDLE", tone: Theme.dim }
  })

  function millis(since) { return typeof since === "number" ? since : Date.parse(since) }

  function elapsed(since) {
    const seconds = Math.max(0, Math.round((now - millis(since)) / 1000))
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
  }

  // The rows to draw: {row, kids, hidden, closed}; `kids` are the rows below
  // it, `hidden` those of them not drawn, folded away or settled.
  readonly property var shown: {
    const byWork = {}
    for (const row of rows)
      byWork[row.work] = row
    const below = {}
    for (const row of rows)
      for (let up = byWork[row.parent]; up; up = byWork[up.parent])
        (below[up.work] = below[up.work] || []).push(row)
    const settled = row => row.state === "done" && now - millis(row.since) > settle
      && (below[row.work] || []).every(kid => kid.state === "done" && now - millis(kid.since) > settle)
    const folding = row => {
      for (let up = byWork[row.parent]; up; up = byWork[up.parent])
        if (folded[up.work] === true)
          return true
      return false
    }
    const hiddenCount = {}
    const drawn = []
    for (const row of rows) {
      if (settled(row) || folding(row)) {
        for (let up = byWork[row.parent]; up; up = byWork[up.parent])
          hiddenCount[up.work] = (hiddenCount[up.work] || 0) + 1
        continue
      }
      drawn.push(row)
    }
    return drawn.map(row => ({
      row: row, kids: (below[row.work] || []).length, hidden: hiddenCount[row.work] || 0,
      closed: folded[row.work] === true
    }))
  }

  readonly property var current: rows.find(row => row.work === picked) || null
  readonly property ListModel said: Omunculus.thread(current ? Omunculus.threadOf(current.work) : "")
  // The newest words in the thread of the picked work, newest last.
  readonly property var words: {
    const found = []
    for (let at = said.count - 1; at >= 0 && found.length < 3; at--) {
      const entry = said.get(at)
      if (entry.text && (current.work === "" || entry.work === "" || entry.work === current.work))
        found.unshift(entry)
    }
    return found
  }

  function fold(work) {
    const next = Object.assign({}, folded)
    next[work] = !next[work]
    folded = next
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8

    // Where the root work stands among its stages.
    ColumnLayout {
      Layout.fillWidth: true
      visible: panel.stage !== null
      spacing: 2
      Label {
        Layout.fillWidth: true
        text: panel.stage ? "Step " + (panel.stage.index + 1) + " of " + panel.stage.count + "  ·  " + panel.stage.name : ""
        color: Theme.foreground
        font.pixelSize: 13
        font.bold: true
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        visible: panel.stage !== null && !!panel.stage.next
        text: panel.stage && panel.stage.next ? "Next: " + panel.stage.next : ""
        color: Theme.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }

    Label {
      Layout.fillWidth: true
      visible: panel.shown.length === 0
      text: "No one is working on this conversation yet."
      color: Theme.dim
      font.pixelSize: 12
      wrapMode: Text.Wrap
    }

    ScrollPage {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.minimumHeight: Math.min(treeRows.implicitHeight, 120)
      contentHeight: treeRows.implicitHeight
      visible: panel.shown.length > 0

      Column {
        id: treeRows
        width: parent.width
        spacing: 2

        Repeater {
          model: panel.shown
          delegate: Rectangle {
            id: line
            required property var modelData
            readonly property var row: modelData.row
            readonly property var look: panel.looks[row.state] || panel.looks.idle
            readonly property bool selected: panel.picked === row.work
            readonly property string detail: row.state === "working" ? (row.phrase || "") : ""

            width: treeRows.width
            height: Math.max(36, body.implicitHeight + 10)
            color: selected ? Qt.tint(Theme.background, Qt.alpha(Theme.primary, 0.1)) : hover.containsMouse ? Theme.highlight : "transparent"
            border.color: selected ? Theme.primary : "transparent"
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: row.agent + ", " + look.word.toLowerCase() + (row.task ? ", " + row.task : "")
            Keys.onReturnPressed: panel.picked = row.work
            Keys.onSpacePressed: panel.picked = row.work
            Keys.onLeftPressed: if (modelData.kids > 0 && !modelData.closed) panel.fold(row.work)
            Keys.onRightPressed: if (modelData.closed) panel.fold(row.work)

            RowLayout {
              id: body
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8 + row.depth * 16; rightMargin: 8 }
              spacing: 8

              // The fold of a team; rows with none below keep the room.
              Item {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                Icon {
                  anchors.centerIn: parent
                  visible: line.modelData.kids > 0
                  name: line.modelData.closed ? "chevron-right" : "chevron-down"
                  size: 12
                  color: Theme.dim
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: line.modelData.kids > 0
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.fold(line.row.work)
                }
              }
              Icon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 5
                name: line.look.icon
                size: 14
                color: line.look.tone
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Label {
                    text: line.row.agent
                    color: Omunculus.toneOf(line.row.agent)
                    font.pixelSize: 13
                    font.bold: true
                  }
                  Label {
                    Layout.fillWidth: true
                    text: line.row.task || ""
                    color: Theme.foreground
                    font.pixelSize: 12
                    elide: Text.ElideRight
                  }
                  Label {
                    visible: line.modelData.hidden > 0
                    text: "(+" + line.modelData.hidden + ")"
                    color: Theme.dim
                    font.pixelSize: 11
                  }
                }
                Label {
                  Layout.fillWidth: true
                  text: line.look.word + (line.row.state === "working" && line.row.since ? "  ·  " + panel.elapsed(line.row.since) : "")
                    + (line.detail !== "" ? "  ·  " + line.detail : "")
                  color: line.row.state === "waiting-you" || line.row.state === "failed" ? line.look.tone : Theme.dim
                  font.pixelSize: 11
                  elide: Text.ElideRight
                }
              }
            }

            MouseArea {
              id: hover
              anchors { fill: parent; leftMargin: 32 }
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { line.forceActiveFocus(); panel.picked = line.row.work }
            }
            FocusRing {}
          }
        }
      }
    }

    // The details of the row picked.
    Kicker { Layout.fillWidth: true; visible: panel.current !== null; text: "Details" }

    ColumnLayout {
      Layout.fillWidth: true
      visible: panel.current !== null
      spacing: 6

      Label {
        Layout.fillWidth: true
        text: panel.current ? panel.current.agent + "  ·  " + (panel.looks[panel.current.state] || panel.looks.idle).word.toLowerCase() : ""
        color: Theme.foreground
        font.pixelSize: 12
        font.bold: true
        elide: Text.ElideRight
      }
      Repeater {
        model: panel.words
        delegate: Label {
          required property var modelData
          Layout.fillWidth: true
          text: modelData.text
          color: Theme.foreground
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }
      Label {
        Layout.fillWidth: true
        visible: panel.words.length === 0
        text: "Nothing said here yet."
        color: Theme.dim
        font.pixelSize: 12
      }
      Repeater {
        model: panel.current ? Omunculus.asked(panel.current.work) : []
        delegate: Label {
          required property var modelData
          Layout.fillWidth: true
          text: "Waiting for an answer: " + (modelData.reason || "a question")
          color: Theme.warning
          font.pixelSize: 12
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }
      TraceButton {
        role: "action"
        dense: true
        text: "OPEN IN LOG"
        icon: "list"
        onClicked: panel.openLog(panel.current.work)
      }
    }
  }
}
