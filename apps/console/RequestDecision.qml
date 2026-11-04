pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Questions.js" as Questions
import "kit/client/Phrases.js" as Phrases
import "kit/client/Requests.js" as Requests
import "kit/ui/focus.js" as Focus
import "kit/ui"

// RequestDecision is one request, wherever it shows, as a card of one of
// three kinds: NEEDS YOU, a question for an answer in words (a numbered list
// of questions has a box for each); YOUR DECISION, with a button for each
// option and an optional note; or PERMISSION, with the scopes that grant it
// and a no with a reason. Its heading says the kind, who asks and on which
// work, and when, with its tools at the right: copy the question, the "more"
// menu that holds ESCALATE, and close where the card can close; under 520 px
// who asks and on which work take a line of their own. The question is shown
// once, as its asker wrote it; when it was passed up, a chip says through
// whom, in order, and opens the wordings of each level and the harness's own
// sentence. Who decides, you or an agent you can overrule, and each decision
// it gathers from below, under its part, are shown as before. The card's
// actions sit at its bottom left: its options, SEND while words are written,
// "I can't answer this", and DENY last; a numbered list's form holds its
// own, which float on the view's bottom edge while the form's end is out of
// view, and the heading counts its answers. Sending shows the answer dimmed at
// once, answered it collapses to the question and your answer, and a failure
// reopens it with the words kept.
SurfaceFrame {
  id: card

  required property string key
  property string stamp: ""
  // Whether the card offers to close, as when it opened in place of another.
  property bool closable: false
  signal closed()

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
  // The subject when it is not the conversation's own, which the masthead has.
  readonly property string about: subject !== Omunculus.subject ? subject : ""
  // Who passed it up, from the asker up, and how each level worded it.
  readonly property var climb: request ? Requests.chain(request).reverse() : []
  // The asker first, then who passed it on toward you: design-lead, seller, sales.
  readonly property var askers: {
    const unique = request ? Requests.route(request, Omunculus.noted[key]) : []
    return unique.length > 0 ? unique : asker !== "" ? [asker] : []
  }
  // Which of its own buttons the card offers, from its state and not from
  // their visibility, which follows the column that holds them.
  readonly property bool sends: open && !formLoader.active && (escalating || (kind !== "permission" && hasWords))
  readonly property bool cannotShown: open && kind === "needs-you" && !formLoader.active && !escalating
  readonly property bool denies: open && options.includes("deny") && !escalating
  readonly property var options: request ? Object.keys(request.options || {}) : []
  // Its own options, then those of the decisions it gathers from below still
  // waiting, each {part, path, options, request}, as an escalation keeps a
  // decision's options on its origin.
  readonly property var choices: request ? Requests.choices(request) : []
  readonly property var own: choices.find(choice => choice.path.length === 0) || null
  readonly property var gathered: choices.filter(choice => choice.path.length > 0)
  // The first name a grant among its decisions gives, as {kind, name}.
  readonly property var wanted: request ? Requests.granted(request) : null
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")

  // The dim tone, kept readable on the card's own fill.
  readonly property color dim: Theme.readableOn(fill)
  readonly property string kind: request ? Requests.kind(request) : ""
  // The question as its asker wrote it.
  readonly property string question: request ? Requests.question(request, Omunculus.noted[key]) : ""
  // The question as a numbered list, when it is one a person answers. Its
  // model is held by value: it changes only when the words of the question do,
  // so the boxes being written in are never rebuilt by a refresh.
  readonly property string formJson: kind === "needs-you" ? JSON.stringify(Questions.parse(question)) : ""
  readonly property var form: formJson === "" ? null : JSON.parse(formJson)
  // Where the answer is: sending, failed, or neither.
  readonly property string delivery: (Omunculus.sending || {})[key] || ""
  readonly property bool busy: delivery === "sending"
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
  property bool wording: false
  readonly property string note: words.text.trim()
  readonly property bool hasWords: note !== ""

  // Put the keyboard in the words, or on the first way to decide.
  function focusWords() {
    const form = formLoader.item as QuestionForm
    if (form && formLoader.active)
      form.focusBox()
    else if (!formLoader.active)
      words.forceActiveFocus()
  }

  onDeliveryChanged: if (delivery === "failed") focusWords()

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
    const reason = card.note
    if (reason === "" || !yours)
      return
    sentText = reason
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.escalate(key, reason)
  }

  // Sends what the words say: the reason it goes up, or an answer in words.
  function submitWords() {
    if (escalating)
      escalate()
    else if (kind !== "permission")
      answerInWords(words.text)
  }

  // What the granted name lets the agent do.
  function unlocks(granted) {
    if (!granted)
      return ""
    if (granted.kind === "resource")
      return { "sandbox.write": "write files in " + (place.root || "its workspace"), "sandbox.network": "use the network" }[granted.name] || "use " + granted.name
    if (granted.kind === "tool")
      return Phrases.act(granted.name) || granted.name.replace(/_/g, " ")
    return "reach " + granted.name
  }

  // How an option of the request, or of a decision it gathers, reads on its
  // button: a grant's scope is that of whoever asked it.
  function labelOf(option, of) {
    const from = of || request
    if (!from)
      return ""
    const job = Omunculus.work(from.work_id || "")
    const where = Omunculus.workspaceOf(job ? job.workspace || "" : "")
    return Requests.optionLabel(option, { who: Requests.label(from.requester), stage: job && job.stage ? job.stage : "", folder: where.name || "" })
  }

  // How many of a numbered list are answered, for the heading.
  readonly property string counted: formLoader.active && formLoader.item ? (formLoader.item as QuestionForm).answered + " OF " + form.items.length + " ANSWERED" : ""

  // Narrow, the header takes two lines.
  readonly property bool stacked: width < Theme.size.measureFrom

  implicitHeight: content.implicitHeight + Theme.space.insetTop + Theme.space.inset
  variant: yours ? "filled" : "outline"
  tone: Theme.warning
  active: yours

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.gap

    // The kind, who asks and on what, how many of a numbered list are
    // answered, and when, beside the tools; under 520 px, who asks, on what
    // and the count go on a line of their own.
    RowLayout {
      Layout.fillWidth: true
      Layout.rightMargin: tools.width + Theme.space.gap
      Layout.minimumHeight: tools.height
      spacing: Theme.space.gap
      Icon { Layout.alignment: Qt.AlignVCenter; name: card.open ? card.badge.icon : "check"; size: 11; color: card.open ? Theme.warning : card.dim }
      Label {
        Layout.alignment: Qt.AlignVCenter
        text: card.open ? card.badge.text : card.answer ? "ANSWERED" : "CLOSED"
        color: card.open && card.yours ? Theme.warning : card.dim
        font.pixelSize: Theme.type.kicker.size
        font.letterSpacing: Theme.type.kicker.tracking
      }
      Asks {
        visible: !card.stacked
        Layout.alignment: Qt.AlignVCenter
        Layout.maximumWidth: content.width * 0.5
        names: card.askers
        dim: card.dim
      }
      Label {
        visible: !card.stacked && text !== ""
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.alignment: Qt.AlignVCenter
        text: card.about
        color: card.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: 1
        elide: Text.ElideRight
      }
      Item {
        visible: card.stacked || card.about === ""
        Layout.fillWidth: true
      }
      Counted {
        visible: !card.stacked && text !== ""
        Layout.alignment: Qt.AlignVCenter
        text: card.counted
        color: card.dim
      }
      Label {
        Layout.alignment: Qt.AlignVCenter
        text: card.stamp
        color: Theme.faint
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }
    }
    RowLayout {
      visible: card.stacked
      Layout.fillWidth: true
      spacing: Theme.space.tight
      Asks {
        Layout.maximumWidth: content.width
        names: card.askers
        dim: card.dim
      }
      Label {
        visible: card.about !== ""
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: "·  " + card.about
        color: card.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: 1
        elide: Text.ElideRight
      }
      Counted {
        visible: text !== ""
        text: card.counted
        color: card.dim
      }
    }

    Label {
      Layout.fillWidth: true
      visible: card.wanted !== null && !card.settled
      text: card.asker + " wants to " + card.unlocks(card.wanted)
      color: Theme.foreground
      font.pixelSize: Theme.type.cardBody.size
      lineHeight: Theme.type.cardBody.lineHeight
      wrapMode: Text.Wrap
    }

    // What the person is asked, in full contrast and at a readable measure;
    // answered, only its first lines stay, dim.
    Prose {
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      visible: !!card.request && card.question !== "" && !card.settled && card.form === null
      source: Omunculus.inline(card.question)
      color: Theme.foreground
      font.pixelSize: Theme.type.cardBody.size
      lineHeight: Theme.type.cardBody.lineHeight
      wrapMode: Text.Wrap
    }
    Label {
      Layout.fillWidth: true
      Layout.maximumWidth: 620
      visible: card.settled
      text: card.question.replace(/\s+/g, " ")
      color: card.dim
      font.pixelSize: Theme.type.body.size
      maximumLineCount: 2
      elide: Text.ElideRight
      wrapMode: Text.Wrap
    }

    Chip {
      Layout.maximumWidth: content.width
      visible: card.passed.length > 0 && !card.settled
      text: "how each level worded it"
      icon: card.wording ? "chevron-up" : "chevron-down"
      tip: card.wording ? "hide how each level worded it" : "show how each level worded it"
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

    Flow {
      id: decides
      readonly property string decider: card.request ? Requests.label(card.request.arbiter) : ""
      Layout.fillWidth: true
      visible: card.open && !card.yours
      Label {
        text: decides.decider.toUpperCase()
        color: Omunculus.toneOf(decides.decider)
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
      Label {
        text: " DECIDES" + Theme.type.meta.separator + "YOU CAN DECIDE INSTEAD"
        color: card.dim
        font.pixelSize: Theme.type.meta.size
        font.letterSpacing: Theme.type.meta.tracking
      }
    }

    // Your answer, or what the agent above chose, as a bubble on the right with
    // its text left aligned: dim while it goes.
    ColumnLayout {
      Layout.fillWidth: true
      visible: card.busy || card.settled
      spacing: Theme.space.line
      Label {
        Layout.alignment: Qt.AlignRight
        text: card.busy ? "SENDING…" : card.answer ? (card.answer.who === "you" ? "YOU ANSWERED" : card.answer.who.toUpperCase() + " ANSWERED") : ""
        color: card.busy ? card.dim : Omunculus.toneOf(card.answer ? card.answer.who : "you")
        font.pixelSize: Theme.type.name.size
        font.letterSpacing: Theme.type.name.tracking
      }
      Rectangle {
        Layout.alignment: Qt.AlignRight
        Layout.maximumWidth: 620
        implicitWidth: Math.min(620, said.implicitWidth + 2 * Theme.size.bubbleInset)
        implicitHeight: said.implicitHeight + Theme.space.inset
        color: Theme.highlight
        opacity: card.busy ? 0.6 : 1
        Label {
          id: said
          anchors { fill: parent; leftMargin: Theme.size.bubbleInset; rightMargin: Theme.size.bubbleInset; topMargin: Theme.space.inset / 2; bottomMargin: Theme.space.inset / 2 }
          text: card.busy ? card.sentText : !card.answer ? "" : (card.answer.option ? card.labelOf(card.answer.option) : "") + (card.answer.option && card.answer.body && card.answer.body !== card.answer.option ? ": " : "") + (card.answer.body && card.answer.body !== card.answer.option ? card.answer.body : "")
          color: card.busy ? card.dim : Theme.foreground
          font.pixelSize: Theme.type.body.size
          lineHeight: Theme.type.body.lineHeight
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.Wrap
        }
      }
    }

    StatusMessage {
      Layout.fillWidth: true
      visible: card.delivery === "failed"
      kind: "error"
      message: "Could not send this. Try again."
    }

    // A numbered list of questions has a form, with its own actions.
    Loader {
      id: formLoader
      Layout.fillWidth: true
      active: card.open && card.form !== null && !card.escalating
      visible: active
      sourceComponent: QuestionForm {
        parsed: card.form
        fill: card.fill
        bleed: Theme.space.inset - card.border.width
        draftKey: card.key
        sending: card.busy
        onSubmitted: text => card.answerInWords(text)
        onDeclined: card.cannotAnswer()
      }
    }

    // In words: an answer that chooses no option, the reason of a no, a note
    // to a choice or, escalating, why it goes up.
    ColumnLayout {
      Layout.fillWidth: true
      visible: card.open && !formLoader.active
      spacing: Theme.space.tight
      Caption {
        text: card.escalating ? "WHY IT GOES UP" : card.kind === "permission" ? "REASON FOR A NO (OPTIONAL)"
          : card.kind === "decision" ? "YOUR NOTE OR ANSWERS (OPTIONAL)" : "YOUR ANSWER"
      }
      TextBlock {
        id: words
        Layout.fillWidth: true
        // One line tall, growing with its text.
        implicitHeight: contentHeight + topPadding + bottomPadding
        readOnly: card.busy
        opacity: readOnly ? 0.5 : 1
        placeholderText: card.escalating ? "why it goes up, for whoever decides above" : card.kind === "needs-you" ? "an answer in words" : card.kind === "decision" ? "answer its questions or add a note" : ""
        Accessible.name: card.escalating ? "why it goes up" : "your words"
        Keys.onPressed: Typing.mark()
        submits: card.kind !== "decision"
        onAccepted: card.submitWords()
      }
    }

    // The card's actions: the decisions it gathers from below, each under its
    // part and who asked it, then its own options, the answer in words, and
    // the no last.
    ColumnLayout {
      id: decisions
      Layout.fillWidth: true
      visible: card.open && (card.gathered.length > 0 || actions.shown || (!!card.own && Requests.always(card.own.options).length > 0))
      enabled: !card.busy
      spacing: Theme.space.gap

      Repeater {
        model: card.open && !card.escalating ? card.gathered : []
        delegate: ColumnLayout {
          id: choice
          required property var modelData
          readonly property var options: modelData.options
          function decide(option) { card.decide(option, card.note, modelData.path) }
          Layout.fillWidth: true
          spacing: Theme.space.tight

          Caption {
            Layout.fillWidth: true
            visible: card.gathered.length > 1
            wrapMode: Text.Wrap
            text: choice.modelData.part.replace(/_/g, " ").toUpperCase() + Theme.type.meta.separator + Requests.label(choice.modelData.request.requester).toUpperCase() + " ASKS"
          }
          Flow {
            Layout.fillWidth: true
            spacing: Theme.space.tight
            Repeater {
              model: Requests.ordered(choice.options.filter(option => !option.startsWith("grant_")))
              delegate: TraceButton {
                required property string modelData
                dense: true
                role: Requests.guarded(modelData) ? "guarded" : "progress"
                icon: modelData === "grant" ? "check" : ""
                text: card.labelOf(modelData, choice.modelData.request)
                onClicked: choice.decide(modelData)
              }
            }
          }
          AlwaysChips {
            options: Requests.always(choice.options)
            labels: options.map(option => card.labelOf(option, choice.modelData.request))
            onChosen: option => choice.decide(option)
          }
        }
      }

      Flow {
        id: actions
        readonly property bool shown: ownOptions.count > 0 || ownGuarded.count > 0 || card.sends || card.cannotShown || card.denies
        Layout.fillWidth: true
        spacing: Theme.space.tight
        Repeater {
          id: ownOptions
          model: card.open && card.own && !card.escalating ? Requests.once(card.own.options) : []
          delegate: TraceButton {
            required property string modelData
            dense: true
            role: "progress"
            icon: modelData === "grant" ? "check" : ""
            text: card.labelOf(modelData)
            onClicked: card.decide(modelData, card.note, [])
          }
        }
        TraceButton {
          id: send
          visible: card.sends
          dense: true
          role: "progress"
          filled: card.hasWords
          icon: card.escalating ? "chevron-up" : "enter"
          text: card.escalating ? "ESCALATE" : "SEND"
          tip: card.escalating ? "raise it, with your words as the reason, to whoever decides above you" : "answer in your words, choosing no option"
          busy: card.busy
          reason: card.escalating && !card.hasWords ? "say why it goes up first" : ""
          onClicked: card.submitWords()
        }
        TraceButton {
          id: cannot
          visible: card.cannotShown
          dense: true
          role: "progress"
          text: "I CAN'T ANSWER THIS"
          tip: "tell the team you can't answer, so they sort it out"
          onClicked: card.cannotAnswer()
        }
        Repeater {
          id: ownGuarded
          model: card.open && card.own && !card.escalating ? card.own.options.filter(option => option === "cancel") : []
          delegate: TraceButton {
            required property string modelData
            dense: true
            role: "guarded"
            text: card.labelOf(modelData)
            onClicked: card.decide(modelData, card.note, [])
          }
        }
        TraceButton {
          id: deny
          visible: card.denies
          dense: true
          role: "guarded"
          icon: "close"
          text: "DENY"
          tip: "say no, with your words as the reason"
          onClicked: card.decide("deny", card.note)
        }
      }

      AlwaysChips {
        options: card.open && card.own && !card.escalating ? Requests.always(card.own.options) : []
        labels: options.map(option => card.labelOf(option))
        onChosen: option => card.decide(option, card.note, [])
      }
    }
  }

  // The card's tools, at its top right: copy the question, the rare actions,
  // and close where it can.
  Row {
    id: tools
    anchors { right: parent.right; top: parent.top; rightMargin: Theme.space.inset; topMargin: Theme.space.insetTop }
    spacing: Theme.space.tight

    IconButton {
      visible: card.question !== ""
      name: "copy"
      tip: "copy the question"
      onClicked: Omunculus.copy(card.question)
    }
    ActionMenu {
      visible: card.yours
      tip: "more"
      items: [card.escalating
        ? { id: "answer", icon: "enter", text: "ANSWER INSTEAD" }
        : { id: "escalate", icon: "chevron-up", text: "ESCALATE" }]
      onChosen: id => {
        card.escalating = id === "escalate"
        card.focusWords()
      }
    }
    IconButton {
      visible: card.closable
      name: "close"
      tip: "close"
      onClicked: card.closed()
    }
  }

  // The count of a numbered list's answers, in the heading's readout type.
  component Counted: Label {
    font.pixelSize: Theme.type.header.size
    font.letterSpacing: Theme.type.meta.tracking
  }

  // Who asks in their tone, then "asks", then how it came to you ("· via
  // seller › sales"); the way elides first.
  component Asks: RowLayout {
    id: asks
    property var names: []
    property color dim
    Layout.fillWidth: false
    spacing: 0
    Label {
      text: asks.names[0] || ""
      color: Omunculus.toneOf(text)
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: 1
    }
    Label {
      text: " asks"
      color: asks.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: 1
    }
    Label {
      visible: asks.names.length > 1
      Layout.fillWidth: true
      Layout.minimumWidth: 0
      text: "  ·  via " + asks.names.slice(1).join(" › ")
      color: asks.dim
      font.pixelSize: Theme.type.meta.size
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
  }

  // Always: each scope a grant is saved for in the project settings, as chips
  // behind a quiet disclosure, so that one click cannot save a standing grant.
  component AlwaysChips: ColumnLayout {
    id: always
    property var options: []
    // How each option reads on its chip.
    property var labels: []
    property bool opened: false
    signal chosen(string option)
    Layout.fillWidth: true
    visible: options.length > 0
    spacing: Theme.space.tight
    Chip {
      text: always.opened ? "ALWAYS ALLOW" + Theme.type.meta.separator + "HIDE" : "ALWAYS ALLOW…"
      onClicked: always.opened = !always.opened
    }
    Caption {
      Layout.fillWidth: true
      visible: always.opened
      wrapMode: Text.Wrap
      text: "SAVED IN THE PROJECT SETTINGS"
    }
    Flow {
      Layout.fillWidth: true
      visible: always.opened
      spacing: Theme.space.tight
      Repeater {
        model: always.options
        delegate: Chip {
          required property string modelData
          required property int index
          text: always.labels[index] || ""
          onClicked: always.chosen(modelData)
        }
      }
    }
  }
}
