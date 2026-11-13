pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "kit/client/Jobs.js" as Jobs
import "kit/client/Questions.js" as Questions
import "kit/client/Events.js" as Events
import "kit/client/Pending.js" as Pending
import "kit/client/Requests.js" as Requests
import "kit/ui/focus.js" as Focus
import "kit/ui"

// RequestDecision is one request, wherever it shows, as an item of one of
// four kinds, each with its icon and word: REVIEW, of an action an account
// holds, with APPROVE, EDIT (which opens the action's text to rewrite) and
// DENY; QUESTION, answered in words (a
// numbered list of questions has a box for each); DECISION, with a button for
// each option; and PERMISSION, with GRANT for this work only, DENY, and an
// "Always…" menu of the wider scopes. Its heading is the kind, the time and
// the item's tools (copy the question, the "more" menu that holds ESCALATE,
// close where the item can close), all on one line; under it the request
// in a sentence, and who asks, the way down from the front desk, the work,
// what it unblocks and, for a permission, what it grants, for a review its step. Every text wraps
// inside the item. The question is shown once, as its asker wrote it; when it
// was passed up, a chip says through whom and opens the wordings of each
// level and the harness's own sentence. Who decides, you or
// another account, and each decision it gathers from below, under its part, are
// shown as before. The actions are one group at the bottom: the options, the
// recommended one (GRANT, APPROVE or ACCEPT) filled and the rest outlined, SEND
// while words are written, "I can't answer this", DENY last and "Always…"
// after it; a numbered list's form holds its own, which float on the view's
// bottom edge while the form's end is out of view, and the heading counts its
// answers. A note, or the reason of a no, is behind ADD A NOTE. Sending shows
// SENDING on the button chosen, which keeps its width; answered it collapses to the question and your
// answer, and a failure reopens it with the words kept. In the chat
// (`collapsible`) a button in the heading folds it to one line, its kind, its
// title, its progress and its time; the words written stay, and the state is
// kept per request while the app runs. The asker, the way down, the work and
// what it unblocks are behind "details". An agent's job proposal is a
// DECISION with its own word, JOB PROPOSAL: under its reason, the job as it
// would run (what it sends, when it holds back, where replies go), and the
// preview of its schedule (JobPreview): the schedule in words, the next fires
// and the estimated cost of a fire. APPROVE creates the job and is filled; EDIT
// sends back, in words, what to change; DENY drops it.
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
  readonly property bool yours: open && Requests.forYou(request, Omunculus.me)
  readonly property var work: request ? Omunculus.work(request.work_id || "") : null
  // The questions it passes on when the harness opened it, each its asker's;
  // its own reason is then only how it came here.
  readonly property var passed: request && Omunculus.noted[key] ? Requests.passedOn(request) : []
  // The climb of its asker's works, the way down, the title and what it asks.
  readonly property var place: Omunculus.workspaceOf(work ? work.workspace || "" : "")
  readonly property string question: request ? Requests.question(request, Omunculus.noted[key]) : ""
  readonly property var facts: request ? Pending.describe(request, {
    me: Omunculus.me, flat: Omunculus.progress ? Omunculus.progress.flat : [], front: Omunculus.agent || Omunculus.lastAgent,
    noted: Omunculus.noted, folder: place.root || "", text: Events.readable(question)
  }) : null
  readonly property string asker: facts ? facts.asker : ""
  // Who passed it up, from the asker up, and how each level worded it.
  readonly property var climb: request ? Requests.chain(request).reverse() : []
  // The answered request this one repeats, and what you said to it.
  readonly property var earlier: open ? Requests.repeated(request, Omunculus.requests, Omunculus.replies) : null
  readonly property var earlierReply: earlier ? Omunculus.replies[earlier.id] : null
  // Which of its own buttons the card offers, from its state and not from
  // their visibility, which follows the column that holds them.
  // A decision is sent by one of its options, which carry the words; SEND
  // would send them with none chosen.
  readonly property bool sends: yours && !formLoader.active && (escalating || editing || kind === "needs-you")
  readonly property bool cannotShown: yours && kind === "needs-you" && !formLoader.active && !escalating
  readonly property bool denies: yours && options.includes("deny") && !escalating
  readonly property var options: request ? Object.keys(request.options || {}) : []
  // Its own options, then those of the decisions it gathers from below still
  // waiting, each {part, path, options, request}, as an escalation keeps a
  // decision's options on its origin.
  readonly property var choices: request ? Requests.choices(request) : []
  readonly property var own: choices.find(choice => choice.path.length === 0) || null
  readonly property var gathered: choices.filter(choice => choice.path.length > 0)
  // The scopes behind "Always…", and the options a grant is made of.
  readonly property var ownActions: own && !escalating ? Pending.actions(own.options, Requests.grants(own)) : { once: [], primary: "", denies: [], always: [] }

  // The dim tone, kept readable on the card's own fill.
  readonly property color dim: Theme.readableOn(fill)
  readonly property string kind: facts ? facts.kind : ""
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
  // What was done to it, as one sentence with its kind's icon and word
  // (ANSWERED, CHOSE, GRANTED, DENIED); null while it waits.
  readonly property var done: settled && request ? Pending.resolved(request, answer, {
    flat: Omunculus.progress ? Omunculus.progress.flat : [], text: Events.readable(question), folder: place.root || ""
  }) : null
  // The lines under the title, as [{name, value, tone, detail}]; those that
  // say who and where are `detail`, behind the toggle.
  // The job it proposes when it is an agent's `propose_job`: it is a decision,
  // approved, sent back with words (EDIT) or denied; it also says what the job
  // sends and, from the server, its schedule's next fires and its estimated cost.
  readonly property var proposal: request ? Jobs.proposal(request) : null
  readonly property var fields: !facts ? [] : (proposal ? Jobs.lines(proposal).filter(line => line.detail) : []).concat([
    { name: "ASKS", value: facts.asker, tone: Omunculus.toneOf(facts.asker), detail: true },
    { name: "PATH", value: facts.path.join(" › "), detail: true },
    { name: "WORK", value: facts.work, detail: true },
    { name: "UNBLOCKS", value: facts.unblocks, detail: true },
    { name: "GRANTS", value: kind === "permission" ? facts.grants : "", tone: Theme.warning },
    { name: "STEP", value: request.interception && request.interception.of > 1 ? request.interception.step + " of " + request.interception.of : "" }
  ]).filter(field => field.value !== "")

  readonly property var shownFields: fields.filter(field => detailed || !field.detail)
  // Whether those details show; each card starts without them.
  property bool detailed: false

  // Whether the card in the chat is folded to one line: as the person left it,
  // else by Pending.startsCollapsed.
  property bool collapsible: false
  readonly property bool collapsed: collapsible && request !== null
    && (Omunculus.folded[key] !== undefined ? Omunculus.folded[key] : Pending.startsCollapsed(request, Omunculus.requests, Omunculus.me))

  // The recommended button of the one decision it gathers, when it has no
  // options of its own.
  property Item recommendedButton: null
  // Whether the words written escalate it rather than answer it.
  property bool escalating: false
  // Whether a review's action is being rewritten: the words replace its text.
  property bool editing: false
  // What is being sent: "path|option" of the option chosen, or "words".
  property string chosen: ""
  property bool wording: false
  // Whether the words of a decision or a permission are open.
  property bool noting: false
  readonly property string note: words.text.trim()
  readonly property bool hasWords: note !== ""
  // The box for words shows for a question and an escalation, and for a
  // decision or a permission once a note is asked for.
  readonly property bool wordsShown: yours && !formLoader.active && (escalating || editing || kind === "needs-you" || noting)

  // Put the keyboard in the words, or on the first way to decide.
  function focusWords() {
    const form = formLoader.item as QuestionForm
    if (form && formLoader.active)
      form.focusBox()
    else if (!formLoader.active && wordsShown)
      words.forceActiveFocus()
  }

  // Puts the keyboard where the answer starts: in its words or form, else on
  // its recommended action, else on the first action.
  function focusFirst() {
    if (!open)
      return
    if (formLoader.active || wordsShown)
      return focusWords()
    const at = ownActions.once.indexOf(ownActions.primary)
    const first = ownOptions.count > 0 ? ownOptions.itemAt(Math.max(0, at)) : recommendedButton
    if (first)
      first.forceActiveFocus()
    else if (deny.visible)
      deny.forceActiveFocus()
    else if (!focusRetried) {
      // Its buttons are not built yet: once more, on the filled one.
      focusRetried = true
      Qt.callLater(focusFirst)
    }
  }
  property bool focusRetried: false

  onDeliveryChanged: if (delivery === "failed") focusWords()

  // An answer or an escalation went out; `keyboard` says whether the
  // keyboard was in the card.
  signal sent(bool keyboard)

  // Chooses an option, with the words as its body: the request's own or, by
  // the parts of path, that of a decision it gathers.
  function decide(option, body, path) {
    chosen = (path || []).join("/") + "|" + option
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.reply(key, option, body, path)
  }

  // Answers in words, choosing no option.
  function answerInWords(text) {
    const body = text.trim()
    if (body === "")
      return
    chosen = "words"
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.reply(key, "", body)
  }

  // Approves a review with the words as the action's text in place of its own.
  function editSent() {
    if (card.note !== "")
      decide("edit", card.note, [])
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
    chosen = "words"
    sent(Focus.within(Window.activeFocusItem, card))
    Omunculus.escalate(key, reason)
  }

  // Opens the held action's text to rewrite, in the words box.
  function startEdit() {
    editing = true
    escalating = false
    Qt.callLater(() => {
      words.text = Requests.editable(request)
      focusWords()
    })
  }

  // Sends what the words say: the reason it goes up, the text that replaces a
  // review's action, or an answer in words.
  function submitWords() {
    if (escalating)
      escalate()
    else if (editing)
      editSent()
    else if (kind !== "permission")
      answerInWords(words.text)
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

  // Whether the card is too narrow to hold its heading's time beside the tools.
  readonly property bool narrow: width < Theme.size.measureFrom

  implicitHeight: content.implicitHeight + Theme.space.insetTop + Theme.space.inset
  variant: yours ? "filled" : "outline"
  tone: Theme.warning
  active: yours

  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: Theme.space.insetTop; leftMargin: Theme.space.inset; rightMargin: Theme.space.inset }
    spacing: Theme.space.gap

    // The kind and the time on the left, the tools on the right; narrow, the
    // tools take a line of their own, and the time leaves for the body.
    GridLayout {
      Layout.fillWidth: true
      columns: card.narrow ? 1 : 2
      columnSpacing: Theme.space.gap
      rowSpacing: Theme.space.line

      RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.gap
        Icon { Layout.alignment: Qt.AlignVCenter; name: card.open && card.facts ? card.facts.icon : card.done ? card.done.icon : "check"; size: 14; color: card.open ? Theme.warning : card.dim }
        Label {
          Layout.alignment: Qt.AlignVCenter
          Layout.fillWidth: !card.collapsed
          Layout.minimumWidth: 0
          text: card.open ? (card.facts ? card.facts.word : "") : card.done ? card.done.word : "CLOSED"
          color: card.open && card.yours ? Theme.warning : card.dim
          font.pixelSize: Theme.type.kicker.size
          font.letterSpacing: Theme.type.kicker.tracking
          elide: Text.ElideRight
        }
        // Collapsed, the title and the progress take the room the heading leaves.
        Label {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          Layout.alignment: Qt.AlignVCenter
          visible: card.collapsed
          text: (card.facts && card.facts.title !== "" ? card.facts.title : Events.readable(card.question).replace(/\s+/g, " ")) + (card.counted !== "" ? "  \u00b7  " + card.counted.toLowerCase() : "")
          color: card.dim
          font.pixelSize: Theme.type.body.size
          elide: Text.ElideRight
        }
      }

      RowLayout {
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        spacing: Theme.space.gap
        Label {
          Layout.alignment: Qt.AlignVCenter
          visible: !card.narrow
          text: card.stamp
          color: Theme.faint
          font.pixelSize: Theme.type.stamp.size
          font.letterSpacing: Theme.type.stamp.tracking
        }
        IconButton {
          visible: card.collapsible
          name: card.collapsed ? "chevron-down" : "chevron-up"
          tip: card.collapsed ? "expand" : "collapse"
          onClicked: Omunculus.fold(card.key, !card.collapsed)
        }
        IconButton {
          visible: card.question !== "" && !card.collapsed
          name: "copy"
          tip: "copy the question"
          onClicked: Omunculus.copy(card.question)
        }
        ActionMenu {
          visible: card.yours && card.kind !== "review" && !card.collapsed
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
    }

    // Everything but the heading folds away while collapsed; what was typed stays.
    ColumnLayout {
      id: body
      Layout.fillWidth: true
      visible: !card.collapsed
      spacing: Theme.space.gap

      // Narrow, the time leaves the heading for a line of its own.
      Label {
        visible: card.narrow && card.stamp !== ""
        text: card.stamp
        color: Theme.faint
        font.pixelSize: Theme.type.stamp.size
        font.letterSpacing: Theme.type.stamp.tracking
      }

      // What it asks, in a sentence, wrapped inside the item.
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: card.open && !!card.facts && card.facts.title !== ""
        text: card.facts ? card.facts.title : ""
        color: Theme.foreground
        font.pixelSize: Theme.type.cardBody.size
        font.bold: true
        lineHeight: Theme.type.cardBody.lineHeight
        wrapMode: Text.Wrap
      }
      Counted {
        visible: text !== ""
        text: card.counted
        color: card.dim
      }
      Prose {
        Layout.fillWidth: true
        Layout.maximumWidth: 620
        visible: card.open && !!card.facts && card.facts.body !== ""
        source: card.facts ? Omunculus.inline(card.facts.body) : ""
        color: Theme.foreground
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        wrapMode: Text.Wrap
      }
      // A permission's own words: why it is asked.
      Prose {
        Layout.fillWidth: true
        Layout.maximumWidth: 620
        visible: card.open && card.kind === "permission" && card.question.trim() !== ""
        source: Omunculus.inline(Events.readable(card.question))
        color: card.dim
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
      }

      // A proposed job: its schedule in words, its next fires and what a fire
      // costs, as the server works them out.
      Loader {
        Layout.fillWidth: true
        Layout.maximumWidth: 620
        active: card.open && card.proposal !== null
        visible: active
        sourceComponent: JobPreview {
          fields: card.proposal
          lines: Jobs.lines(card.proposal).filter(line => !line.detail)
          dim: card.dim
        }
      }
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        visible: card.settled
        text: Events.readable(card.question).replace(/\s+/g, " ")
        color: card.dim
        font.pixelSize: Theme.type.body.size
        maximumLineCount: 2
        elide: Text.ElideRight
        wrapMode: Text.Wrap
      }

      // Who asks, the way down, the work and what it unblocks: behind the toggle.
      Chip {
        Layout.maximumWidth: body.width
        visible: card.open && card.fields.some(field => field.detail)
        text: "details"
        icon: card.detailed ? "chevron-up" : "chevron-down"
        tip: card.detailed ? "hide who asks, the path and the work" : "show who asks, the path and the work"
        onClicked: card.detailed = !card.detailed
      }
      ColumnLayout {
        Layout.fillWidth: true
        visible: card.open && card.shownFields.length > 0
        spacing: Theme.space.line
        Repeater {
          model: card.open ? card.shownFields : []
          delegate: RowLayout {
            id: field
            required property var modelData
            Layout.fillWidth: true
            spacing: Theme.space.gap
            Caption { Layout.preferredWidth: 80; Layout.alignment: Qt.AlignTop; text: field.modelData.name }
            Label {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              text: field.modelData.value
              color: field.modelData.tone !== undefined ? field.modelData.tone : Theme.foreground
              font.pixelSize: Theme.type.body.size
              font.bold: field.modelData.name === "ASKS"
              wrapMode: Text.Wrap
            }
          }
        }
      }

      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.maximumWidth: 620
        visible: card.earlierReply !== null
        text: card.earlierReply ? "asked again after your answer at " + card.earlierReply.stamp + ": " + (Events.readable(card.earlierReply.option && card.earlierReply.body === card.earlierReply.option ? Requests.optionText(card.earlierReply.option) : card.earlierReply.body || Requests.optionText(card.earlierReply.option)).replace(/\s+/g, " ").trim()) : ""
        color: card.dim
        font.pixelSize: Theme.type.meta.size
        maximumLineCount: 1
        elide: Text.ElideRight
      }

      Chip {
        Layout.maximumWidth: content.width
        visible: (card.passed.length > 0 || card.climb.length > 1) && !card.settled
        text: "how each level worded it"
        icon: card.wording ? "chevron-up" : "chevron-down"
        tip: card.wording ? "hide how each level worded it" : "show how each level worded it"
        onClicked: card.wording = !card.wording
      }

      // How each level above the asker worded it, then the harness's sentence.
      Label {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        Layout.maximumWidth: 620
        visible: (card.passed.length > 0 || card.climb.length > 1) && card.wording && !card.settled
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
          text: " DECIDES"
          color: card.dim
          font.pixelSize: Theme.type.meta.size
          font.letterSpacing: Theme.type.meta.tracking
        }
      }

      // Your answer, or what the agent above chose, as a bubble on the right with
      // its text left aligned. While it goes, the button chosen says SENDING.
      ColumnLayout {
        Layout.fillWidth: true
        visible: card.settled
        spacing: Theme.space.line
        Label {
          Layout.alignment: Qt.AlignRight
          text: card.answer ? (card.answer.who === "you" ? "YOU ANSWERED" : card.answer.who.toUpperCase() + " ANSWERED") : ""
          color: Omunculus.toneOf(card.answer ? card.answer.who : "you")
          font.pixelSize: Theme.type.name.size
          font.letterSpacing: Theme.type.name.tracking
        }
        Rectangle {
          Layout.alignment: Qt.AlignRight
          Layout.maximumWidth: 620
          implicitWidth: Math.min(620, said.implicitWidth + 2 * Theme.size.bubbleInset)
          implicitHeight: said.implicitHeight + Theme.space.inset
          color: Theme.highlight
          Label {
            id: said
            anchors { fill: parent; leftMargin: Theme.size.bubbleInset; rightMargin: Theme.size.bubbleInset; topMargin: Theme.space.inset / 2; bottomMargin: Theme.space.inset / 2 }
            text: !card.answer ? "" : (card.answer.option ? card.labelOf(card.answer.option) : "") + (card.answer.option && card.answer.body && card.answer.body !== card.answer.option ? ": " : "") + (card.answer.body && card.answer.body !== card.answer.option ? card.answer.body : "")
            color: Theme.foreground
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
        active: card.yours && card.form !== null && !card.escalating
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

      // A note to a decision or a permission is asked for.
      Chip {
        visible: card.yours && !formLoader.active && !card.escalating && !card.editing && card.kind !== "needs-you" && !card.noting
        icon: "plus"
        text: card.kind === "permission" ? "ADD A REASON OR A NOTE" : "ADD A NOTE"
        onClicked: {
          card.noting = true
          Qt.callLater(card.focusWords)
        }
      }

      // In words: an answer that chooses no option, the reason of a no, a note
      // to a choice or, escalating, why it goes up.
      ColumnLayout {
        Layout.fillWidth: true
        visible: card.wordsShown
        spacing: Theme.space.tight
        Caption {
          Layout.fillWidth: true
          text: card.escalating ? "WHY IT GOES UP" : card.editing ? (card.proposal ? "WHAT TO CHANGE IN THE JOB" : "WHAT IT WILL DO INSTEAD") : card.kind === "permission" ? ("REASON FOR A NO (OPTIONAL)")
            : card.kind === "decision" ? "YOUR NOTE OR ANSWERS (OPTIONAL)" : "YOUR ANSWER"
        }
        TextBlock {
          id: words
          Layout.fillWidth: true
          // One line tall, growing with its text.
          implicitHeight: contentHeight + topPadding + bottomPadding
          readOnly: card.busy
          opacity: readOnly ? 0.5 : 1
          placeholderText: card.escalating ? "why it goes up, for whoever decides above" : card.editing ? (card.proposal ? "what the agent should change in the job" : "the text to go ahead with") : card.kind === "needs-you" ? "type your answer" : card.kind === "decision" ? "answer its questions or add a note" : "a reason or a note"
          Accessible.name: card.escalating ? "why it goes up" : "your words"
          Keys.onPressed: Typing.mark()
          submits: card.kind !== "decision" && card.kind !== "review"
          onAccepted: card.submitWords()
        }
      }

      // The decisions it gathers from below, each under its part and who asked
      // it, as a group of its own.
      Repeater {
        model: card.yours && !card.escalating ? card.gathered : []
        delegate: ColumnLayout {
          id: choice
          required property var modelData
          readonly property var parts: Pending.actions(modelData.options, Requests.grants(modelData))
          function decide(option) { card.decide(option, card.note, modelData.path) }
          Layout.fillWidth: true
          enabled: !card.busy
          spacing: Theme.space.tight

          Caption {
            Layout.fillWidth: true
            visible: card.gathered.length > 1
            wrapMode: Text.Wrap
            text: choice.modelData.part.replace(/_/g, " ").toUpperCase() + Theme.type.meta.separator + Requests.label(choice.modelData.request.requester).toUpperCase() + " ASKS"
          }
          ActionGroup {
            label: "options of " + Requests.label(choice.modelData.request.requester)
            Repeater {
              model: choice.parts.once.concat(choice.parts.denies)
              delegate: TraceButton {
                id: gatheredOption
                required property string modelData
                // The one decision gathered is recommended like the card's own.
                readonly property bool recommended: modelData === choice.parts.primary && card.gathered.length === 1
                dense: true
                role: Requests.guarded(modelData) ? "guarded" : "progress"
                filled: recommended && card.yours
                sending: card.busy && card.chosen === choice.modelData.path.join("/") + "|" + modelData
                icon: modelData === "grant" ? "check" : Requests.guarded(modelData) ? "close" : "diamond"
                text: card.labelOf(modelData, choice.modelData.request)
                onClicked: choice.decide(modelData)
                Component.onCompleted: if (recommended) card.recommendedButton = gatheredOption
              }
            }
            AlwaysMenu {
              options: choice.parts.always
              labels: options.map(option => card.labelOf(option, choice.modelData.request))
              onChosen: option => choice.decide(option)
            }
          }
        }
      }

      // The card's own actions, as one group: its options, the answer in words,
      // and the no last, then the wider scopes of a grant.
      ActionGroup {
        id: actions
        readonly property bool shown: ownOptions.count > 0 || ownGuarded.count > 0 || card.sends || card.cannotShown || card.denies || card.ownActions.always.length > 0
        label: "actions"
        visible: card.yours && actions.shown
        enabled: !card.busy

        Repeater {
          id: ownOptions
          model: card.yours && !card.escalating ? card.ownActions.once.filter(option => !(card.editing && option === "edit")) : []
          delegate: TraceButton {
            required property string modelData
            dense: true
            role: "progress"
            filled: modelData === card.ownActions.primary && card.yours
            sending: card.busy && card.chosen === "|" + modelData
            icon: modelData === "grant" || modelData === "approve" ? "check" : modelData === "edit" ? "edit" : "diamond"
            text: card.labelOf(modelData)
            onClicked: modelData === "edit" ? card.startEdit() : card.decide(modelData, card.note, [])
          }
        }
        TraceButton {
          id: send
          visible: card.sends
          dense: true
          role: "progress"
          filled: card.hasWords
          icon: card.escalating ? "chevron-up" : "enter"
          text: card.escalating ? "ESCALATE" : card.editing ? (card.proposal ? "SEND CHANGES" : "SEND EDIT") : "ANSWER"
          tip: card.escalating ? "raise it, with your words as the reason, to whoever decides above you" : card.editing ? (card.proposal ? "send your words back to the agent, which proposes the job again" : "let it go ahead with your words in place of its text") : "answer in your words, choosing no option"
          sending: card.busy && (card.chosen === "words" || card.editing)
          reason: card.hasWords ? "" : card.escalating ? "say why it goes up first" : card.editing ? (card.proposal ? "say what to change first" : "write the text it goes ahead with first") : "type your answer first"
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
          model: card.yours && card.own && !card.escalating ? card.own.options.filter(option => option === "cancel") : []
          delegate: TraceButton {
            required property string modelData
            dense: true
            role: "guarded"
            sending: card.busy && card.chosen === "|" + modelData
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
          sending: card.busy && card.chosen === "|deny"
          tip: "say no, with your words as the reason"
          onClicked: card.decide("deny", card.note)
        }
        AlwaysMenu {
          options: card.ownActions.always
          labels: options.map(option => card.labelOf(option))
          onChosen: option => card.decide(option, card.note, [])
        }
      }
    }
  }

  // The count of a numbered list's answers, in the heading's readout type.
  component Counted: Label {
    Layout.fillWidth: true
    Layout.minimumWidth: 0
    font.pixelSize: Theme.type.header.size
    font.letterSpacing: Theme.type.meta.tracking
  }
}
