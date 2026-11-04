pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/client/Progress.js" as Progress

// ProgressStrip is the conversation's progress on two lines, pinned over the
// chat: the stages of the work in focus, then who works on it, from its agent
// down to the one at work, what that one does and for how long. A question
// waiting on you takes the second line, with ANSWER; a finished work says how
// long it took. Both lines are fitted in characters to their width. The
// chevron opens and closes the full view. Hidden while nothing was handed
// to anyone and no agent runs.
Item {
  id: strip

  // Omunculus.progress, or null; whether the full view is open.
  property var progress: null
  property bool expanded: false
  // The time of the conversation's newest event, in seconds; 0 when unknown.
  property real lastEvent: 0
  // Seconds of silence after which a working team is said to have no news.
  readonly property int quiet: 600

  signal toggle()
  signal answer()

  readonly property string phase: progress ? progress.state : "idle"
  readonly property var focusNode: progress ? progress.focus : null
  readonly property var forYou: progress ? progress.forYou : []
  readonly property var path: progress ? progress.path : []
  readonly property var now: progress ? progress.now : null
  readonly property real tick: Omunculus.tick
  readonly property bool working: phase === "working"
  readonly property int silence: working && lastEvent > 0 ? Math.round(tick - lastEvent) : 0

  // Line 2's parts, for Progress.fit: the chain above the agent at work gives
  // way first, then what it does; the agent and the clock stay.
  readonly property var parts: {
    if (forYou.length > 0) {
      const asker = forYou[0].asker
      const asks = forYou.filter(ask => ask.asker === asker).length
      return [{ text: asker + " asks you", elide: true, keep: true },
              { text: " · " + asks + (asks === 1 ? " question" : " questions"), keep: true }]
    }
    if (phase === "done") {
      const took = focusNode ? focusNode.finishedIn || focusNode.branch.seconds : 0
      return [{ text: "Finished", keep: true }, { text: " · took " + Progress.span(took) }]
    }
    if (!now || !now.agent)
      return [{ text: focusNode ? focusNode.doing : "", elide: true, keep: true }]
    const above = path.map(step => step.agent).filter(agent => agent && agent !== now.agent)
    const clock = now.since !== null && working ? Progress.clock(Math.max(0, Math.round(tick - now.since))) : ""
    return (above.length > 0 ? [{ text: above.join(" › ") + " › ", short: "…› " }] : [])
      .concat([{ text: now.agent, keep: true }, { text: ": " + now.doing, elide: true }])
      .concat(clock !== "" ? [{ text: " · " + clock, keep: true }] : [])
  }

  readonly property string stall: silence > quiet ? " · no news for " + Progress.span(silence) : ""

  visible: progress !== null && (progress.roots.length > 0 || phase !== "idle")
  implicitHeight: visible ? 52 : 0
  Accessible.role: Accessible.StatusBar
  Accessible.name: progress ? progress.spoken : ""

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: strip.toggle()
  }

  RowLayout {
    anchors { fill: parent; leftMargin: 4; rightMargin: 0 }
    spacing: 10

    // The state: the trace while working, unless motion is reduced.
    Item {
      Layout.preferredWidth: 28
      Layout.preferredHeight: 12
      Layout.alignment: Qt.AlignVCenter
      LoadingTrace {
        anchors.centerIn: parent
        width: 28
        height: 10
        running: strip.working && !Theme.reducedMotion
        tone: Theme.primary
      }
      StateMark {
        anchors.centerIn: parent
        visible: !strip.working || Theme.reducedMotion
        state: strip.working ? "" : strip.forYou.length > 0 ? "needs-you" : strip.phase
        showWord: false
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      Layout.alignment: Qt.AlignVCenter
      spacing: 4

      // Line 1: the stages of the work in focus, else its title.
      Stepper {
        Layout.fillWidth: true
        visible: steps.length > 0
        size: 12
        steps: strip.focusNode ? strip.focusNode.steps : []
        round: strip.focusNode ? strip.focusNode.round : 0
        tip: strip.focusNode ? strip.focusNode.title : ""
      }
      Label {
        Layout.fillWidth: true
        visible: !strip.focusNode || strip.focusNode.steps.length === 0
        text: strip.focusNode ? strip.focusNode.title : Omunculus.subject
        color: Theme.foreground
        font.pixelSize: 12
        font.bold: true
        elide: Text.ElideRight
      }

      // Line 2: who works and what on, fitted; the silence, when long, after it.
      RowLayout {
        Layout.fillWidth: true
        spacing: 0
        Item {
          id: room
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          implicitHeight: second.implicitHeight
          property int slack: 0
          readonly property int budget: Math.max(1, Math.floor(width / Math.max(1, metrics.advanceWidth("0"))) - slack)
          readonly property string fitted: width > 0 ? Progress.fit(parts, budget).join("") : ""
          readonly property var parts: strip.parts
          onWidthChanged: slack = 0
          onPartsChanged: slack = 0
          FontMetrics { id: metrics; font: second.font }
          TextMetrics {
            id: drawn
            font: second.font
            text: room.fitted
            onAdvanceWidthChanged: Qt.callLater(() => { if (drawn.advanceWidth > room.width + 0.5 && room.slack < 3) room.slack++ })
          }
          Label {
            id: second
            width: room.width
            text: room.fitted
            color: strip.forYou.length > 0 ? Theme.warning : Theme.dim
            font.pixelSize: 11
            elide: Text.ElideRight
          }
        }
        Label {
          visible: strip.stall !== ""
          Layout.maximumWidth: strip.width * 0.4
          text: strip.stall
          elide: Text.ElideRight
          color: Theme.warning
          font.pixelSize: 11
        }
      }
    }

    Chip {
      visible: strip.forYou.length > 0
      Layout.alignment: Qt.AlignVCenter
      text: "ANSWER"
      accent: Theme.warning
      checked: true
      onClicked: strip.answer()
    }

    IconButton {
      Layout.alignment: Qt.AlignVCenter
      implicitWidth: 32
      implicitHeight: 32
      name: strip.expanded ? "chevron-up" : "chevron-down"
      tip: (strip.expanded ? "close" : "open") + " the progress"
      onClicked: strip.toggle()
    }
  }
}
