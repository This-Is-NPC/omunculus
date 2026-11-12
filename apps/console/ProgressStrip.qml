pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/ui"
import "kit/client/Progress.js" as Progress
import "kit/client/Shortcuts.js" as Shortcuts

// ProgressStrip is the conversation's head, one block that says what is
// happening now, once: an icon and a sentence in words ("Seller is waiting for
// your answer", "Designer is working on the design stage"), how long, the cost
// when there is one, and ANSWER, in the warning tone, while something waits on
// you; under them, compact, the stages of the work in focus (`Stepper`). It
// draws nothing while there is nothing to say, so no empty frame shows. A done
// conversation leads, from its sentence, to what was delivered. The agents
// that ran are the tree's to show, the figures the cost's.
Rectangle {
  id: strip

  // Omunculus.progress, or null; how many requests wait on you.
  property var progress: null
  property int waiting: 0
  // The dollars the conversation has cost at its models' prices, 0 for none.
  property real spent: 0

  signal answer()
  // The result of a done conversation is wanted.
  signal openResult()
  // The cost is wanted.
  signal openCost()

  readonly property var focusNode: progress ? progress.focus : null
  // The agent the conversation is with.
  readonly property string who: Omunculus.agent || Omunculus.lastAgent
  readonly property var standing: Progress.standing(progress, who)
  readonly property bool working: !!progress && progress.state === "working"
  // Whether the person's message is in the thread, even still sending.
  readonly property bool said: {
    const entries = Omunculus.thread("")
    for (let at = 0; at < entries.count; at++) {
      if (entries.get(at).mine)
        return true
    }
    return false
  }
  // What is happening, or null.
  readonly property var line: Progress.status({
    progress: progress, standing: standing, tick: Omunculus.tick, said: said, ran: Omunculus.runs.length > 0,
    verb: working && progress.now.doing ? Progress.lively(progress.now.doing, progress.now.since, Omunculus.tick) : ""
  })
  readonly property color ink: !line ? Theme.dim : ({ working: Theme.primary, warning: Theme.warning, error: Theme.error, success: Theme.success, quiet: Theme.dim })[line.tone]
  readonly property bool done: !!progress && progress.state === "done"

  visible: line !== null
  color: "transparent"
  border.color: Theme.line
  implicitHeight: column.implicitHeight + Theme.space.insetTop + Theme.space.insetTop
  Accessible.role: Accessible.StatusBar
  Accessible.name: line ? line.text + (line.clock !== "" ? ", " + line.clock : "") : ""

  ColumnLayout {
    id: column
    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.tight

    RowLayout {
      Layout.fillWidth: true
      spacing: Theme.space.gap

      Icon {
        Layout.alignment: Qt.AlignVCenter
        name: strip.line ? strip.line.icon : ""
        size: Theme.type.cardBody.size
        color: strip.ink
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: strip.line ? strip.line.text : ""
        color: strip.ink
        font.pixelSize: Theme.type.cardBody.size
        font.bold: true
        elide: Text.ElideRight
        font.underline: lead.containsMouse
        // Done, the sentence leads to what was delivered.
        activeFocusOnTab: strip.done
        Keys.onReturnPressed: if (strip.done) strip.openResult()
        Keys.onSpacePressed: if (strip.done) strip.openResult()
        MouseArea {
          id: lead
          anchors.fill: parent
          enabled: strip.done
          hoverEnabled: true
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: strip.openResult()
        }
        Hint { active: lead.containsMouse; text: "show what was delivered" }
      }
      Label {
        visible: !!strip.line && strip.line.clock !== ""
        text: strip.line ? strip.line.clock : ""
        color: Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
      Label {
        id: cost
        visible: strip.spent > 0
        text: Omunculus.money(strip.spent)
        color: costPointer.containsMouse ? Theme.foreground : Theme.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
        font.underline: costPointer.containsMouse
        MouseArea {
          id: costPointer
          anchors { fill: parent; margins: -Theme.space.tight }
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: strip.openCost()
        }
        Hint { active: costPointer.containsMouse; text: "what this conversation has cost; open the cost" }
      }
      TraceButton {
        Layout.alignment: Qt.AlignVCenter
        visible: strip.waiting > 0
        dense: true
        role: "progress"
        tone: Theme.warning
        icon: "enter"
        text: "ANSWER" + (strip.waiting > 1 ? "  " + strip.waiting : "")
        tip: "answer the newest question waiting on you" + (strip.waiting > 1 ? ", of " + strip.waiting : "") + "  " + Shortcuts.label("reply")
        onClicked: strip.answer()
      }
    }

    // The stages of the work in focus.
    Stepper {
      Layout.fillWidth: true
      visible: steps.length > 0
      size: Theme.type.cardBody.size
      steps: strip.focusNode ? strip.focusNode.steps : []
      round: strip.focusNode ? strip.focusNode.round : 0
      tip: strip.focusNode ? strip.focusNode.title : ""
    }
  }
}
