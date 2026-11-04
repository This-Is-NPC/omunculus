pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Time.js" as Time
import "kit/ui"

// WorkSummary is a work as the map's inspector and the work's page show it:
// its title and goal, where it works, its workflow and stage, the work it
// came from, which opens when clicked; what it asked and still waits for, to
// answer in place; and the notes it left you, to mark read.
ColumnLayout {
  id: summary

  // The work, or "" for the root agent's own conversation.
  required property string key
  // Whether it shows the work whole — its title, goal, where it works, its
  // workflow and the work it came from — or, on the work's page, which shows
  // those itself, only what it asked and its notes.
  property bool whole: true
  signal picked(string key)

  readonly property var work: key !== "" ? Omunculus.work(key) : null
  readonly property var parentWork: work ? Omunculus.work(work.parent_id || "") : null
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")

  spacing: Theme.space.gap

  Label {
    Layout.fillWidth: true
    visible: summary.whole
    text: summary.work ? summary.work.title : Omunculus.title
    font.pixelSize: 13
    wrapMode: Text.Wrap
  }
  Prose {
    Layout.fillWidth: true
    visible: summary.whole && summary.work !== null && !!summary.work.goal && summary.work.goal !== summary.work.title
    source: summary.work ? Omunculus.inline(String(summary.work.goal || "")) : ""
    color: Theme.dim
    font.pixelSize: 12
    wrapMode: Text.Wrap
  }

  GridLayout {
    Layout.fillWidth: true
    visible: summary.whole
    columns: 2
    columnSpacing: 12
    rowSpacing: 6
    Caption { text: "WORKSPACE" }
    Label {
      Layout.fillWidth: true
      text: (summary.place.name ? summary.place.name + "  ·  " : "") + summary.place.root
      font.pixelSize: 11
      elide: Text.ElideMiddle
    }
    Caption { visible: !!summary.work && !!summary.work.workflow; text: "WORKFLOW" }
    Label {
      visible: !!summary.work && !!summary.work.workflow
      text: summary.work && summary.work.workflow ? summary.work.workflow + "  ·  stage " + summary.work.stage : ""
      font.pixelSize: 11
    }
    Caption { visible: summary.parentWork !== null; text: "FROM" }
    Label {
      visible: summary.parentWork !== null
      text: summary.parentWork ? (summary.parentWork.assignee || "").toUpperCase() + "  ·  " + summary.parentWork.title : ""
      color: from.containsMouse ? Theme.primary : Theme.foreground
      font.pixelSize: 11
      font.underline: from.containsMouse
      elide: Text.ElideRight
      Layout.fillWidth: true
      MouseArea {
        id: from
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: summary.picked(summary.parentWork.id)
      }
    }
  }

  Repeater {
    model: Omunculus.asked(summary.key)
    delegate: RequestDecision {
      required property var modelData
      Layout.fillWidth: true
      key: modelData.id
      stamp: Time.clock(modelData.created_at, Date.now())
    }
  }

  Repeater {
    model: Omunculus.unreadFrom(summary.key)
    delegate: SurfaceFrame {
      id: note
      required property var modelData
      Layout.fillWidth: true
      implicitHeight: noted.implicitHeight + Theme.space.insetTop * 2
      variant: "filled"
      tone: Theme.warning
      RowLayout {
        id: noted
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
        spacing: Theme.space.tight
        Prose {
          Layout.fillWidth: true
          source: Omunculus.inline(Omunculus.notes[note.modelData.id] || "")
          font.pixelSize: 12
          wrapMode: Text.Wrap
        }
        IconButton { Layout.alignment: Qt.AlignTop; name: "check"; tip: "mark read"; onClicked: Omunculus.markRead(note.modelData.id) }
      }
    }
  }
}
