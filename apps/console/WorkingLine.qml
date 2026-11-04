import QtQuick
import QtQuick.Layouts
import "kit/ui"

// WorkingLine says whether something is happening, above the composer: one
// line from the conversation's activity, with the state's icon, what the team
// is doing, which step it is on and for how long. A question waiting for you
// leads to its card; a team at work, to the team. It is hidden when idle. The
// trace moves only while the team works.
Item {
  id: line

  // The result of Activity.status, or null.
  property var activity: null
  // The time of the newest event of the conversation, in seconds; 0 when unknown.
  property real lastEvent: 0
  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  signal showQuestion()
  signal openTeam()

  readonly property string state: activity ? activity.state : "idle"
  readonly property bool working: state === "working"
  readonly property bool waitsOnYou: state === "waiting-you"
  property double now: Date.now()
  readonly property int elapsed: activity && activity.since ? Math.max(0, Math.round(now / 1000 - activity.since)) : 0
  readonly property bool stalled: working && lastEvent > 0 && now / 1000 - lastEvent > quiet
  readonly property var stage: activity ? activity.stage || null : null
  // The headline of a working team already names its step.
  readonly property string step: !working && stage && stage.count > 0 ? "STEP " + stage.index + " OF " + stage.count : ""
  readonly property color tone: ({ working: Theme.primary, "waiting-you": Theme.warning, "waiting-team": Theme.warning, done: Theme.success, failed: Theme.error })[state] || Theme.dim
  readonly property string word: ({ working: "Working", "waiting-you": "Waiting for you", "waiting-team": "Waiting for the team", done: "Done", failed: "Failed" })[state] || ""
  readonly property string icon: ({ working: "spark", "waiting-you": "warning", "waiting-team": "people", done: "check", failed: "close" })[state] || ""
  // What a screen reader hears: it changes with the state and at most every 30 s.
  property string spoken: ""

  function clock(seconds) {
    return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
  }

  function announce() { spoken = word + ": " + (activity ? activity.headline : "") }
  onStateChanged: announce()
  Component.onCompleted: announce()

  visible: state !== "idle"
  implicitHeight: visible ? 34 : 0
  Accessible.role: Accessible.StatusBar
  Accessible.name: spoken

  // The time counts in seconds while the team works; speech is renewed slowly.
  Timer { running: line.working; interval: 1000; repeat: true; triggeredOnStart: true; onTriggered: line.now = Date.now() }
  Timer { running: line.working; interval: 30000; repeat: true; onTriggered: line.announce() }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: line.openTeam()
  }

  RowLayout {
    anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
    spacing: 10

    Icon { Layout.alignment: Qt.AlignVCenter; name: line.icon; size: 12; color: line.tone }
    LoadingTrace {
      Layout.alignment: Qt.AlignVCenter
      Layout.preferredWidth: 56
      Layout.preferredHeight: 14
      visible: line.working && !Theme.reducedMotion
      running: line.working && !Theme.reducedMotion
      tone: line.tone
    }
    Icon { visible: line.working && Theme.reducedMotion; Layout.alignment: Qt.AlignVCenter; name: "more"; size: 12; color: line.tone }
    Label {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      text: line.activity ? line.activity.headline : ""
      color: Theme.foreground
      font.pixelSize: 11
      elide: Text.ElideRight
    }
    Label {
      visible: line.working && !!line.activity.loop
      Layout.alignment: Qt.AlignVCenter
      text: line.activity ? line.activity.loop : ""
      color: Theme.dim
      font.pixelSize: 11
    }
    Label { visible: line.step !== ""; Layout.alignment: Qt.AlignVCenter; text: line.step; color: Theme.dim; font.pixelSize: 11 }
    Label { visible: line.stalled; Layout.alignment: Qt.AlignVCenter; text: "NO NEWS FOR 10 MIN"; color: Theme.warning; font.pixelSize: 11 }
    Label { visible: line.working; Layout.alignment: Qt.AlignVCenter; text: line.clock(line.elapsed); color: Theme.dim; font.pixelSize: 11 }
    Chip {
      visible: line.waitsOnYou
      Layout.alignment: Qt.AlignVCenter
      text: "Show"
      accent: Theme.warning
      onClicked: line.showQuestion()
    }
  }
}
