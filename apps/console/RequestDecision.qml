pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/client/Requests.js" as Requests
import "kit/ui/focus.js" as Focus
import "kit/ui"

// RequestDecision is one request, wherever it shows, as a card of one of
// three kinds: NEEDS YOU, a question for an answer in words (a numbered list
// of questions has a box for each); YOUR DECISION, with a button for each
// option and an optional note; or PERMISSION, with the scopes that grant it
// and a no with a reason. The header says the kind, who asks and on which
// work, on two lines when the card is narrow. The question is shown as its
// asker wrote it; when it was passed up, a chip says through whom, in order,
// and opens the wordings of each level and the harness's own sentence. Who
// decides, you or an agent you can overrule, and each decision it gathers
// from below, under its part, are shown as before. "I can't answer this"
// sends the team a plain reply. Sending shows the answer dimmed at once,
// answered it collapses to the question and your answer, and a failure
// reopens it with the words kept. ESCALATE is under MORE.
SurfaceFrame {
  id: card

  required property string key
  property string stamp: ""

  readonly property var request: Omunculus.requests.find(item => item.id === key) || null
  readonly property var answer: Omunculus.replies[key] || null
  readonly property bool open: request !== null && Requests.pending(request)
  readonly property bool yours: open && Requests.human(request.arbiter)
  readonly property var work: request ? Omunculus.work(request.work_id || "") : null
  // The questions it passes on when the harness opened it, each its asker's;
  // its own reason is then only how it came here.
  readonly property var passed: request && Omunculus.noted[key] ? Requests.passedOn(request) : []
  readonly property string asker: passed.length > 0 ? Requests.label(passed[0].requester) : request ? Requests.label(request.requester) : ""
  // The work it concerns: the origin's when the harness passed it up, else the
  // conversation's own subject.
  readonly property var origin: passed.length > 0 ? Omunculus.work(passed[0].work_id || "") : null
  readonly property string subject: origin ? origin.title : work ? work.title : Omunculus.subject
  // Who passed it up, from the asker up, and how each level worded it.
  readonly property var climb: request ? Requests.chain(request).reverse() : []
  readonly property string passers: climb.slice(1).map(level => Requests.label(level.requester)).join(" › ")
  readonly property var options: request ? Object.keys(request.options || {}) : []
  // Its own options, then those of the decisions it gathers from below still
  // waiting, each {part, path, options, request}, as an escalation keeps a
  // decision's options on its origin.
  readonly property var choices: request ? Requests.choices(request) : []
  // The first name a grant among its decisions gives, as {kind, name}.
  readonly property var wanted: request ? Requests.granted(request) : null
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")

  // The dim tone, kept readable on the card's own fill.
  readonly property color dim: Theme.readableOn(fill)
  readonly property string kind: request ? Requests.kind(request) : ""
  // The question as its asker wrote it.
  readonly property string question: passed.length > 0 ? passed.map(origin => origin.reason).join("\n\n") : request ? String(request.reason || "") : ""
  // The question as a numbered list, when it is one a person answers. Its
  // model is held by value: it changes only when the words of the question do,
  // so the boxes being written in are never rebuilt by a refresh.
  readonly property string formJson: kind === "needs-you" ? JSON.stringify(Questions.parse(question)) : ""
  readonly property var form: formJson === "" ? null : JSON.parse(formJson)
  // Where the answer is: sending, failed, or neither.
  readonly property string state: (Omunculus.sending || {})[key] || ""
  readonly property bool busy: state === "sending"
  // Answered by you or on your behalf, and no longer waiting.
  readonly property bool settled: !open && answer !== null
  readonly property var badge: ({
    "needs-you": { text: "NEEDS YOU", icon: "warning" },
    decision: { text: "YOUR DECISION", icon: "warning" },
    permission: { text: "PERMISSION", icon: "key" },
    team: { text: "TEAM", icon: "people" }
  })[kind] || { text: "", icon: "warning" }

  // Whether the words written escalate it rather than answer it.
  property bool escalating: false
  // What was sent, shown while it goes.
  property string sentText: ""
  property bool more: false
  // The words are the reason it goes up, not an answer.
  readonly property bool raising: escalating || (form !== null && more)
  property bool wording: false

  // Put the keyboard in the words, or on the first way to decide.
  function focusWords() { (formLoader.item || words).focusBox() }
  function focusDecision() {
    const first = content.nextItemInFocusChain(true)
    if (first && Focus.within(first, content))
      first.forceActiveFocus()
    else
      focusWords()
  }

  onStateChanged: if (state === "failed") focusWords()

  // An answer or an escalation went out; `keyboard` says whether the
  // keyboard was in the card.
  signal sent(bool keyboard)

  // Chooses an option, with the words as its body: the request's own or, by
  // the parts of path, that of a decision it gathers.
  function decide(option, body, path) {
    sentText = body !== "" ? body : labelOf(option)
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.reply(key, option, body, path)
  }

  // Answers in words, choosing no option.
  function answerInWords(text) {
    const body = text.trim()
    if (body === "")
      return
    sentText = body
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.reply(key, "", body)
  }

  // Tells the team that you cannot answer, in words they read as any answer.
  function cannotAnswer() {
    answerInWords("I can't answer this one; please sort it out with the team.")
  }

  // Raises it, with the words as the reason, to whoever decides above you.
  function escalate() {
    const reason = words.text.trim()
    if (reason === "" || !yours)
      return
    sentText = reason
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.escalate(key, reason)
  }

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

  // How an option of the request, or of a decision it gathers, reads on its
  // button: a grant's scope is that of whoever asked it.
  function labelOf(option, of) {
    const from = of || request
    if (!from)
      return ""
    const who = Requests.label(from.requester)
    const job = Omunculus.work(from.work_id || "")
    const where = Omunculus.workspaceOf(job ? job.workspace || "" : "")
    return ({
      grant: "THIS WORK ONLY",
      grant_agent: "FOR " + who.toUpperCase(),
      grant_depth: "FOR ITS LEVEL",
      grant_stage: "IN THE " + String(job && job.stage ? job.stage : "").toUpperCase() + " STAGE",
      grant_workspace: where.name ? "IN FOLDER " + where.name : "IN THE PROJECT",
      deny: "DENY"
    })[option] || option.replace(/_/g, " ").toUpperCase()
  }

  // Narrow, the header takes two lines.
  readonly property bool stacked: width < 520

  implicitHeight: content.implicitHeight + 24
  variant: yours ? "filled" : "outline"
  tone: Theme.warning
  active: yours

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 14; rightMargin: 14 }
    spacing: 10

    // The kind, who asks and on what, and when; under 520 px, who asks and
    // on what go on a line of their own.
    RowLayout {
      Layout.fillWidth: true
      spacing: 10
      Icon { Layout.alignment: Qt.AlignVCenter; name: card.open ? card.badge.icon : "check"; size: 12; color: card.open ? Theme.warning : card.dim }
      Label {
        Layout.alignment: Qt.AlignVCenter
        text: card.open ? card.badge.text : card.answer ? "ANSWERED" : "CLOSED"
        color: card.open && card.yours ? Theme.warning : card.dim
        font.pixelSize: 11
        font.letterSpacing: 1.5
      }
      Item {
        visible: card.stacked
        Layout.fillWidth: true
      }
      Label {
        visible: !card.stacked
        Layout.alignment: Qt.AlignVCenter
        Layout.maximumWidth: content.width * 0.4
        text: card.asker + " asks"
        color: Omunculus.toneOf(card.asker)
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Label {
        visible: !card.stacked
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignVCenter
        text: card.subject
        color: card.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
      Label { Layout.alignment: Qt.AlignVCenter; text: card.stamp; color: card.dim; font.pixelSize: 11 }
    }
    RowLayout {
      visible: card.stacked
      Layout.fillWidth: true
      spacing: 6
      Label {
        Layout.maximumWidth: content.width * 0.6
        text: card.asker + " asks"
        color: Omunculus.toneOf(card.asker)
        font.pixelSize: 12
        elide: Text.ElideRight
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: "·  " + card.subject
        color: card.dim
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.wanted !== null
      text: "asks for " + (card.wanted ? card.wanted.name : "") + "  —  to " + card.unlocks(card.wanted)
      color: Theme.foreground
      font.pixelSize: 13
      wrapMode: Text.Wrap
    }

    // What the person is asked, in full contrast and at a readable measure.
    Prose {
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      visible: !!card.request && card.question !== "" && !card.settled && card.form === null
      source: Omunculus.inline(card.question)
      color: Theme.foreground
      font.pixelSize: 13
      wrapMode: Text.Wrap
    }

    // Answered: only the first line of the question stays.
    Label {
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      visible: card.settled
      text: card.question.replace(/\s+/g, " ")
      color: card.dim
      font.pixelSize: 12
      maximumLineCount: 2
      elide: Text.ElideRight
      wrapMode: Text.Wrap
    }

    Chip {
      Layout.maximumWidth: content.width
      visible: card.passed.length > 0 && !card.settled
      text: "passed up by " + (card.passers !== "" ? card.passers : "the harness")
      icon: card.wording ? "chevron-up" : "chevron-down"
      onClicked: card.wording = !card.wording
    }

    // How each level above the asker worded it, then the harness's sentence.
    Label {
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      visible: card.passed.length > 0 && card.wording && !card.settled
      text: card.climb.slice(1).map(level => Requests.label(level.requester) + ": " + String(level.reason || "")).concat(card.request ? [String(card.request.reason || "")] : [])
        .filter(line => line.trim() !== "").join("\n\n")
      color: card.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    Label {
      Layout.fillWidth: true
      visible: card.open && !card.yours
      text: card.request ? Requests.label(card.request.arbiter).toUpperCase() + " DECIDES  ·  YOU CAN DECIDE INSTEAD" : ""
      color: card.dim
      font.pixelSize: 11
      wrapMode: Text.Wrap
    }

    // Your answer, or what the agent above chose, as a bubble on the right with
    // its text left aligned: dim while it goes.
    ColumnLayout {
      Layout.fillWidth: true
      visible: card.busy || card.settled
      spacing: 4
      Rectangle {
        Layout.alignment: Qt.AlignRight
        Layout.maximumWidth: 620
        implicitWidth: Math.min(620, said.implicitWidth + 24)
        implicitHeight: said.implicitHeight + 16
        color: Qt.alpha(Theme.foreground, 0.06)
        border.color: Theme.line
        opacity: card.busy ? 0.6 : 1
        Label {
          id: said
          anchors { fill: parent; margins: 8; leftMargin: 12; rightMargin: 12 }
          text: card.busy ? card.sentText : !card.answer ? "" : (card.answer.option ? card.labelOf(card.answer.option) : "") + (card.answer.option && card.answer.body && card.answer.body !== card.answer.option ? ": " : "") + (card.answer.body && card.answer.body !== card.answer.option ? card.answer.body : "")
          color: card.busy ? card.dim : Theme.foreground
          font.pixelSize: 12
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.Wrap
        }
      }
      Label {
        Layout.alignment: Qt.AlignRight
        text: card.busy ? "Sending..." : card.answer ? (card.answer.who === "you" ? "You answered" : card.answer.who.toUpperCase() + " answered") : ""
        color: card.dim
        font.pixelSize: 11
      }
    }

    StatusMessage {
      Layout.fillWidth: true
      visible: card.state === "failed"
      kind: "error"
      message: "Could not send this. Try again."
    }

    // Each decision as buttons, given with the words written: the request's
    // own options, then those of each decision it gathers from below, under
    // its part and who asked it; for this work only, then always.
    Repeater {
      model: card.open ? card.choices : []
      delegate: ColumnLayout {
        id: choice
        required property var modelData
        readonly property bool own: modelData.path.length === 0
        readonly property var options: modelData.options
        // The request's own deny goes with the words, as the reason of a no.
        readonly property var once: options.filter(option => option !== "grant" && !option.startsWith("grant_") && !(own && option === "deny"))
        readonly property var always: options.filter(option => option.startsWith("grant_"))
        function decide(option) { card.decide(option, words.text.trim(), modelData.path) }
        Layout.fillWidth: true
        enabled: !card.busy
        spacing: 6

        Caption {
          Layout.fillWidth: true
          visible: !choice.own
          wrapMode: Text.Wrap
          text: choice.modelData.part.replace(/_/g, " ").toUpperCase() + "  ·  " + Requests.label(choice.modelData.request.requester).toUpperCase() + " ASKS"
        }
        Flow {
          Layout.fillWidth: true
          visible: choice.options.includes("grant") || choice.once.length > 0
          spacing: 6
          TraceButton {
            visible: choice.options.includes("grant")
            dense: true
            role: "primary"
            icon: "check"
            text: card.labelOf("grant", choice.modelData.request)
            onClicked: choice.decide("grant")
          }
          Repeater {
            model: choice.once
            delegate: TraceButton {
              required property string modelData
              dense: true
              role: modelData === "deny" || modelData === "cancel" ? "guarded" : "progress"
              text: card.labelOf(modelData, choice.modelData.request)
              onClicked: choice.decide(modelData)
            }
          }
        }
        // Always: each scope a grant saved in the project settings.
        Caption {
          Layout.fillWidth: true
          visible: choice.always.length > 0
          wrapMode: Text.Wrap
          text: "ALWAYS  ·  SAVED IN THE PROJECT SETTINGS"
        }
        Flow {
          Layout.fillWidth: true
          visible: choice.always.length > 0
          spacing: 6
          Repeater {
            model: choice.always
            delegate: Chip {
              required property string modelData
              text: card.labelOf(modelData, choice.modelData.request)
              onClicked: choice.decide(modelData)
            }
          }
        }
      }
    }

    // In words: an answer that chooses no option, the reason of a no, a note
    // to a choice or, when it waits on you, why it goes up. A numbered list of
    // questions has a form instead.
    Loader {
      id: formLoader
      Layout.fillWidth: true
      active: card.open && card.form !== null && !card.raising
      visible: active
      sourceComponent: QuestionForm {
        parsed: card.form
        draftKey: card.key
        sending: card.busy
        onSubmitted: text => card.answerInWords(text)
        onDeclined: card.cannotAnswer()
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      visible: card.open && (card.form === null || card.raising)
      spacing: 6
      TextArea {
        id: words
        Layout.fillWidth: true
        Layout.maximumWidth: 620
        dense: true
        sending: card.busy
        invalid: card.state === "failed"
        label: card.raising ? "WHY IT GOES UP" : card.kind === "permission" ? "REASON FOR A NO (OPTIONAL)"
          : card.kind === "decision" ? "ADD A NOTE (OPTIONAL)" : "YOUR ANSWER"
        placeholderText: card.raising ? "why it goes up, for whoever decides above" : card.kind === "needs-you" ? "an answer in words" : ""
        onSubmitted: text => card.raising ? card.escalate() : card.kind !== "permission" && card.answerInWords(text)
      }
      Flow {
        Layout.fillWidth: true
        spacing: 6
        TraceButton {
          visible: card.kind !== "permission" && !card.raising
          dense: true
          role: "primary"
          icon: "enter"
          text: "SEND"
          enabled: words.text.trim() !== "" && !card.busy
          onClicked: card.answerInWords(words.text)
        }
        TraceButton {
          visible: card.options.includes("deny")
          dense: true
          role: "guarded"
          icon: "close"
          text: "DENY"
          enabled: !card.busy
          onClicked: card.decide("deny", words.text.trim())
        }
      }
    }

    Flow {
      Layout.fillWidth: true
      visible: card.open
      spacing: 6
      TraceButton {
        visible: card.kind === "needs-you" && !formLoader.active
        dense: true
        role: "progress"
        text: "I CAN'T ANSWER THIS"
        enabled: !card.busy
        onClicked: card.cannotAnswer()
      }
      TraceButton {
        visible: card.yours && !card.escalating
        dense: true
        role: "progress"
        icon: "more"
        text: "MORE"
        onClicked: card.more = !card.more
      }
      TraceButton {
        visible: card.yours && (card.more || card.escalating)
        dense: true
        role: card.raising ? "primary" : "progress"
        icon: "chevron-up"
        text: "ESCALATE"
        enabled: words.text.trim() !== "" && !card.busy
        onClicked: card.escalate()
      }
    }
  }
}
