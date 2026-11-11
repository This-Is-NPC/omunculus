# The console

`apps/console/` is a client of the server, like any other: it never opens
the store or the TOML.

## Requirements and launch

It needs Quickshell, `curl` with WebSocket support and a Wayland session.
`apps/kit/run console` takes the server registry and, optionally, a project
id. `mix omunculus.socket` resolves the project's socket, and the launcher
passes both as `OMUNCULUS_SOCKET` and `OMUNCULUS_PROJECT`, as it does for
every app. Without an id, a registry of one project opens on it; a registry
of several opens on the registry itself, with an empty `OMUNCULUS_PROJECT`
and the socket of one of its projects, from which `GET /v1/projects` lists
them all. `--project` is where the window starts, not a lock: any project of
the registry opens from PROJECTS.

## How it reads the project

The `Omunculus` singleton holds the project as the window sees it and makes
every request through `curl` on the project's local socket. Views only bind
that singleton. The conversation's event stream is `curl` on its WebSocket,
whose frames `EventStream` splits into events. It reads the snapshot again
after each event. Every event is also a row of `eventLog` (`EventLog`, a
`ListModel`), taken at any rate and moved into the rows by a 150 ms timer, so
a burst costs one layout; it is emptied for another conversation. From the
state it derives, soon after each change, the `progress` (the kit's
`Progress.build`): the conversation's state, one node per work nested under
the stage that handed it down, the work in focus and the path from it to the
agent at work, what waits on you, and each branch's time, calls and cost. The
stages a work went through, its rounds and who sent it back or stopped it
come from the `continue`, `reopen` and `break` events (`Progress.journal`,
in `journeys`); the calls and the last thing done on each work (`callsOf`) and
the model usage by work come from the `tool` and `model` events. A clock,
`tick`, moves every second while a run is open, and the views count their
elapsed times from it. It keeps when each run started and why it ended
(`runStarts`, from the events), and, for each request being answered,
`sending` or `failed` until the answer is read back.

Every time shown is local, formatted by the kit's `Time.js`: a chat stamp is
"21:59" today, "Yesterday 21:59" or "03 Nov 21:59".

The theme and the controls more than one app uses are in `apps/kit/ui`, a
copy of eco's overlay, Omarchy's voice session app. Every request goes
through `apps/kit/client`'s `Http`, which finds the scripts beside it. Each
app reaches the kit through its `kit` link to `apps/kit/`, since Quickshell
imports only from within the folder it runs.

## How it reads the registry

While the window is entered, at any level, `Omunculus` follows every project
the window's socket lists (`GET /v1/projects`, `watchRegistry`): on its own
socket, its conversations (`GET /conversations`), each one's snapshot for
its summary, its works (`GET /works`) and its setup, then its project
stream. An event re-summarizes only the conversation it is of and reads
again only its project's works, once events pause for 250 ms; a new
conversation reads its project's conversations again. A project whose
socket does not answer is marked not reachable. The kit's `Projects.js`
turns all of it into `projectRows`, one per project, sorted by the
conversations needing you first, then those working, then the latest
activity, then the id, and `elsewhere`, the conversations needing you in
the projects the window is not on. A project whose conversations, or any
summary of them, are not read yet is `reading` and counts none, so no count
shows partial: `elsewhere` is 0 while another project is read. A conversation's state comes from its
summary (`Projects.state`): NOT STARTED, NEEDS YOU while a request waits on
you, WORKING while its agents run, DONE, FAILED when nothing runs and the
last run to end ended in an error, or IDLE; the snapshot does not say why a
run ended, so a conversation with nothing running, waiting or done has its
events read for that, a page at a time; every count of
conversations on the start, PROJECTS and CONVERSATIONS is of those states,
so they agree. The summary (`Projects.summary`) also keeps whom the
conversation is with (the agent of its first run at depth 0), what waits
on you by kind (each item of a numbered question counted), since when, and
what the newest request asks. The start follows the projects too, while it
is on screen, for its count of what needs you.

`switchProject` moves the window to another project: the conversation on
screen closes (its agents go on), and the project's conversations, setup
and capabilities are read once its socket answers. The window's conversations
are read again whenever the project's stream announces a conversation, made by
anyone (the mailbox, another window), and whenever the conversations page
opens; the list shows every conversation the person may read, whoever began it.
What was typed in the
chat's composer and not sent is kept by conversation (`composerDrafts`) and
comes back when it opens again.

## A new conversation

A new conversation opens, from CONVERSATIONS or the start, on a screen of its
own: the composer addressed to the project's default agent, the one its
`omunculus.toml` names in `[policy] default_agent`, read from the setup
(`Omunculus.startAgent`, through the kit's `Mailbox.defaultAgent`, as the
mailbox reads it). Over the box, "TO" and a folded control with the agent's
tone and name. Without a default agent, and with several agents of depth 0
not only in workflows, TO starts empty, its list is open and SEND says "choose
who it goes to" until one is picked; with a single such agent, TO names it.

Opening the control (a click, or Enter, Space or Down on it) lists the other
agents of depth 0 (`Recipient`), opt-in: the project's own first, a line each
with its tone, its name and its role, the first sentence of its text without a
leading "You are the", then, under FOR THE PROJECT ITSELF, the agents of the
system pack (the setup's pack named `system`), which change how the project's
agents work, each change only once you approve it; a line's tooltip gives the
model it runs on. Up and Down move along the list, Enter or a click picks and
puts the keyboard in the box, and Esc folds the list before it goes back.
Picking another agent replaces the recipient. Nothing is made on the server by
a pick: the first message makes the conversation and then sends, and the chat
opens on it. If making it fails, the words stay in the box and a toast says
so; BACK returns where the screen was opened from. The conversation keeps the
agent its first message named, and every message names it again.

The start card says the same, derived from the setup: "Say what you need; it
goes to front-desk unless you choose another", with the default agent's name
(or "Say what you need and choose who gets it" without one).

A conversation opened from CONVERSATIONS that has no message yet names no agent
until its first message; its chat shows the same TO control over the composer
while several agents of depth 0 may take it, addressed to the default agent
when there is one, with the list open when there is none. With one agent, the
server names it.

## Threads

The console folds the events into threads: the main one, the dialogue between
you and the root agent, and one per work (handed down, or a root work a run
opened), where its agent's runs show. A run on any other work, or none,
belongs to the main thread.

Every kind of entry has its own form, the same across the thread. Messages are
filled bubbles: each line (`SpeechTurn`) and each agent's turn that speaks
(`AgentTurn`) is a bubble under a heading of its speaker's tone dot, name and
time, as in eco: yours on the right, filled with the text's ink at a low
alpha; an agent's on the left, filled with a tint of its colour
(`Theme.bubble`); a line that continues the same speaker's turn drops the
heading. Body text in every bubble and card reads at more than 10:1 on its
fill. The main thread, the chat, holds only the dialogue, the work cards and what
you answered (below). Everything else an agent did is the log, and shows in a
work's own thread: system rows (`LogLine`, `ToolCalls`, `SubWorkBlock`, the
exchange's line), unframed, at the log's smaller size (`Theme.type.log`), dim,
each with its icon in a mark column of their own (`Theme.size.mark`) and its
time at the right, so they read as secondary to what was said. The chat shows no portraits; they
stay in a work's detail. A turn's heading says how
long the run has worked, in the short form used everywhere: "Working 12 s"
while it is open, "Worked 3 min" after. An agent's name and dot take its tone (`Omunculus.toneOf`) wherever
it is named: the turns, the header strip, its lines and the cards. Tones go
by the order agents first appear in the conversation on screen, from the
agent you wrote to, and stay while it is open; no two are within 30° of
hue, and none within 30° of the accent, success, warning or error. A theme
whose colours leave little room yields fewer tones, and they then repeat. The board's agents have their own, in the order the window meets them.
While
an agent works for a work's thread, its end holds a live line (`Progress.live`):
a dot breathing in the tone of the agent at work, the agents from the one you
wrote to down to that one, each in its tone ("project-manager › design-lead ›
designer"; short of room the first give way to "…"), "working" and its clock,
the trace at the row's end, and under them what it does: "Thinking · wrote
files", with "· no news for 12 minutes" after ten minutes without an event. A
call is recorded once it finished, but the model event that asked for it is
known: while it runs the line says it as it goes ("Running a command"), and
between calls it says the last one in the past, after "Thinking"; a run that
has made no call for 15 s reads "Thinking", not "Getting started"; "· round N"
follows the clock once a work is sent back. It updates in place, and it gives
way to that agent's own turn while the turn streams in the thread and shows
something. A thread nested in a sub-work block has none, the block says it.
In the chat it shows whoever works, down the team, at every width, with the
chain from the agent you write to; a run that ends leaves no line, so the chat
does not tell the team's work run by run; the work's thread, the tree and the
log do. A run of
the agent you write to that fails shows in the header strip (FAILED) and the
log. A conversation opens
at its end, and while earlier entries lie above the view an EARLIER pill at
its top counts them and leads to the start, where the dialogue opens on a mark,
"START OF THE CONVERSATION" with when it began. Once the thread outgrows the view
it keeps a free band at each end, for that pill and the NEW one, so a pill
never covers an entry; when the question waiting on you
is taller than the view, the thread lands at its top with the entry before it
whole above, never cut by the view.
Once its words are whole, the "more" button beside them, in a gutter
they never take, copies them or shows the log of the run's work (the
thread's `openLog`).

A note the harness left, as when it stopped a work and tells you so, is no
one's words: it reads NOTE, muted, where a speaker's name would be, as in
the mailbox, and the log names its events' actor `harness`.
A harness note about a question you already see as a card (its request is
one the harness opened or gathers) says nothing new: it is not shown, not
counted as unread, and marked read when you answer.

What an agent says, a request's reason and a work's goal and notes are the
kit's `Prose`, their web addresses links that open in the browser.

Under its words, a turn's tool calls are one group (`ToolCalls`, from the
kit's `Calls.group`), system rows behind the step mark ("›_"), its chevron
after the words; in the chat a turn is its words alone, and one that only
acted is not drawn: its steps are the work's. A turn that said nothing is that line alone, with no
heading: its agent in its tone leads it and how long it worked ends it,
"sales  Passed your answers to seller · worked 3 s", the time at the right.
Folded, one line counts them, how many failed and the
first that did, in plain words: "9 steps · 1 failed: could not move to the next stage"; a lookup that found nothing (a folder not there yet) is no failure; a lone call that went well is named by what it did ("Passed a question up", "Looked in design/", "Ran: npx build"; a reply, by whom it answers: "Passed your answer to seller", or "answers" for a numbered form), and a turn that says nothing names its agent on that line, so these lines never stand under no name. While the run is open its last three calls show
live under it. Unfolded, each call is a row with the raw tool name and its args
in brief (`Phrases.brief`: the path of a file tool, the command of `bash`, whom an `ask` or
`escalate` goes to and never its question, which its card or exchange shows,
the first work a `work` call opens), and a failed call shows its output, six
lines and then all on demand. An `edit` opens a small diff of the lines it
replaced, a `write` the first lines it wrote. Every call is shown, those
chained through another tool too; the hooks that ran without trouble are one
row, "3 hooks ran". What moved the work is a row in plain words: "moved on to
design", "sent "Home page" back to design", "stopped: ...", "granted ...". A
turn that has said and done nothing yet is not drawn. An entry that draws
nothing takes no room, not even the gap between entries, and words with no
text and no files are not added to the thread.

A work handed down is one card in the chat (`WorkCard`), where it was: the
kicker WORK, its title, its state as an icon and a word (WORKING, WAITING FOR
SURGEON, WAITING FOR YOU, DONE, FAILED, CANCELLED, as the tree says it) and how
long, a WAITS line when it waits on others ("seller is waiting for surgeon")
and OPEN IN TREE, which opens the team page with that work picked. A card has
no stages, no one at work, no runs and no steps: where the work stands is the
progress strip's alone, what the agent at work does is the live line's, and
the runs are in the tree. Its data is the progress node (`Pending.workCard`). In a
work's own thread the same entry is a block (`SubWorkBlock`), where the run
handed it down; so is a root work a run opened. A system row
behind the branch mark, "sub-work" with its agent, title and time, it says on
a second line its state, for how long and
how many steps (tool calls; hook runs are not steps, here and in the turn):
with those of the works it handed down, then how many are its own ("34 steps
· 20 its own"), so the count moves while the team works; and, when some
failed, how many, what was attempted and why the first failed ("5 failed:
could not move to the next stage (reason)"), in the error tone only if the work itself
failed; when each failed tool later succeeded, a dim "5 retried" instead,
its stages when it has a workflow, and the round with
who sent it back. A comment on a work of the conversation's own (not one nested below it) also
appears in the main thread at its own time, as a quoted card (`TeamNote`):
outlined, headed by a quote mark, NOTE FROM and the agent in its tone, the
time at its right, and the text at the body size in the full tone, at most as
wide as a bubble, six lines and then unfolding by its heading; for the
newest note once the conversation's work is done, its result: DELIVERED BY and
the agent, in the success tone, whole and as wide as the thread. The strip's "✓ DONE" then takes the chat to it. Its addresses are links
in the accent. It is the team's news, not a message to you. Until the work's data arrives, it shows the title the event
named and "Handing down…", or nothing when the event named none. A work that
waits on a branch says who works below it ("● designer working", in the
working tone) and else what it waits for. Waiting on you reads "⚠ NEEDS YOU",
as everywhere, in the line's frame, since only the card can be acted on; the
conversation's own work leaves out its title and stages, which the masthead
and the strip show. Choosing it unfolds it in place, in an outlined frame under its row, into the tabs
01 TRANSCRIPT (the work's own thread, at most 480 px tall with its own
scroll), 02 CHANGES and 03 RUNS; a block two levels down does not unfold.
The open glyph at its top right shows the work's thread as a page of its own
(see [Pages](#pages)).

The thread is in the order of the events' own times, which the server
records in order: a row sits where its event happened, a run's end line at
the time the run ended and a question at the time it was asked. An answer
shown under its question keeps the time it was given, so it can read later
than the lines after the question.

A request waiting on you is not in the thread: it is in the pending queue (see
[Requests](#requests)). What you did to one is a sentence in the chat
(`ResolvedLine`), with its kind's icon and word and the time at the right: "?
ANSWERED  You answered sales' 5 questions (Doce Ana: sale)", "◇ CHOSE  You
chose approve on seller's decision (Doce Ana: sale)", "⛨ GRANTED  You granted
surgeon permission to use the network (Build: Doce Ana)", DENIED for a no
(`Pending.resolved`); a saved scope adds it ("· for surgeon"), and adjust
reads "You asked seller to adjust". Under 520 px the word is over the
sentence, which ends with the time. Sending an answer, like sending a
message, takes the view to the end, so it never counts as news; a reply says
nothing in the bar when it succeeds. The view follows the end until you scroll
up: the live row's growing never ends it, and only your own scrolling, to more
than a row from the end, does. The NEW pill counts the entries below the view
that draw something, so it is gone when the end is in view; it sits in a band
of its own above the composer, so it never covers an entry.

What an agent asks another is an exchange (`TeamRow`) in a work's thread, not
in the chat: a system row behind the people mark, "seller asked design-lead ·
design-lead decides", each agent in its tone, and under it, in an outlined
frame at the body size, the question in its first three lines and, once
answered, who answered and what. It is open while it waits, and DECIDE INSTEAD opens the request's
card in place, to answer it yourself. A request another gathers (`Requests.contained`), as the
lower ones of a question passed up, is not shown on its own.

## The progress

A conversation's pages share its head (`ProgressStrip`), over the tabs, which
says where the conversation stands at a glance. First a 40 px header strip
with its meta: the state, the workflow of the work in focus, the step it is at
of how many, how many are left, and how long it has run, in words: "WORKING ·
ENGAGEMENT · STEP 4 OF 5 · 1 LEFT · 48 MINUTES SO FAR" (the clock runs from
the work's start while anything runs, with no event needed; `Progress.standing`
and `Progress.track` give the workflow and the step, and the step is the last
once the work is done). The state is WORKING, WAITING, STOPPED, "✓ DONE" in the
success tone, "✕ FAILED" in the error tone, or "NEEDS YOUR ANSWER" in the
warning tone; once done, "TOOK 3 MINUTES" replaces the clock; "WAITING FOR YOU
SINCE 22:43", in the warning tone, replaces it while a question waits on you,
also when the work asking is a sub-work; before any work, "STARTING" while the
first run goes or the person has written, NOT STARTED before any. As the width
shrinks the workflow and the count of what is left give way first, then the
step to "4/5". From 700 px of its own width the counts follow: "· 2 AGENTS ·
US$ 0.04", shown when more than one agent ran and once the provider priced a
call; each opens what it counts, the tree and the cost, and the agents' tip
names them. At its right the chevron, which opens the full view, and ANSWER,
in the warning tone and with the count when more than one waits, while a
question waits on you, which opens the pending queue. Under it, unframed, the stages of the work in focus, the newest open
root work, at 14 px, the largest line of the head (`Stepper`: "✓ qualify › ● design · round 2 › ○ assess …", shorter
forms as the width shrinks, down to one dot per stage and the current name), or
its title when it has no stages and the masthead does not already say it; and,
while the conversation works or waits, the line of who: what it is doing — AT
WORK, WAITING FOR YOU, or WAITING FOR the agents it waits for — and the chain
of agents from the one you talk with down to the one at work or waited for,
each in its tone and the last in bold, "front-desk › project-manager ›
administrator › design-reviewer", then, while it works, a plain verb ("· running
a command") and how long it has been on it. This head is the one place that says
where the work stands: the work cards in the chat repeat neither the stages nor
the chain. The hierarchy reads there before the tree is opened. Once you have written,
the stages' line keeps its room, blank until there is something to say, so the
tabs below hold their place from the first message. A finished conversation
says "✓ DONE · … · TOOK 1 HOUR 20 MINUTES" in the success tone in the strip's
top line, and the lines under it are hidden while no work exists and no agent
runs.

The chevron and Alt+P open the full view, on the chat
(`ProgressSheet`, holding a `ProgressTree`): what waits on you with ANSWER,
then each root work, newest open first, with its title, start and length,
its stages one per row with their agent and time, and under each stage the
works handed down while it was current, nested by level (`ProgressNode`).
An open work is a framed card: its agent and state, its title, its stages,
what it calls, the round with who sent it back and why, the questions it
asked and its tool calls; a done, cancelled or coming one is one line, what
is below it folded. Siblings handed down in one stage are headed "N in
parallel", and the done and cancelled works of each place fold into one
row, "✓ 2 sub-works done · 18 min", with "· 9 in all" when works lie below
them, unless a question waiting on you climbed from there. Picking a work shows its agent's last words, its questions in
full, and OPEN (its thread as a page), LOG (the log kept to it) and TREE (the
tree page, the work picked). ↑/↓ move, → unfolds, ← folds, Enter opens
or folds, Esc returns to the composer.

A work's state follows its questions up their climb. An escalated question
is held by the pending request that gathers it, at any depth
(`Requests.holder`). A question for you counts once, for the deepest work it
climbed from (`Requests.works`): that work alone needs you, even when the
request now waiting on you belongs to no work, as one an agent at depth 0
escalated. The works it climbed through wait ("Waiting for your answer to
design-lead"); one whose question an agent holds waits on that agent. The
NEEDS YOU chip of the tree counts these questions. A work waiting for an answer that is not read yet says
"Waiting for an answer". The works above one that needs you keep their own
state, and a done or coming one there is not folded.

Where it opens depends on the window's width: from 1100 px it is docked
beside the thread, 380 px wide and the page's height, and open from the
start once the conversation has a work; from 700 px it is a card under the
strip, pushing the thread down, at most 55 % of the chat's height and
scrolling inside; under 700 px it is a sheet over the whole chat, headed
‹ CHAT, PROGRESS and a close button, which Esc closes. Below 1100 px it starts
closed.

Alt+R, as ANSWER and the counter under the head, opens the pending queue, from
any page of the conversation. Esc closes it, or, in the progress, returns to
the composer. The composer has no options of a request above it: they are
answered in the queue.

The composer is the kit's `TextArea` in a frame with a chevron: one line that
grows with the text up to eight lines, then scrolls. Enter sends, Shift+Enter
breaks the line, and a pasted text keeps its line breaks. While the agent
written to works, SEND keeps its caption with the trace along its foot, its
tip says "sales is working; SEND still sends", and it still sends. SEND is
dim while the box is empty. A sent message empties the box at once and shows
in the thread as your bubble, dim, with SENDING… where the time goes, until the
server's copy replaces it in place; if the server refuses it, the bubble goes
and the words come back to the box. Under 420 px its
buttons show their icons only.

The clip in the composer's frame picks files for the message, which show
over the box as chips (the kit's `FilePicker`, a click takes one off) and
are sent through `Http.post`. A file a message or an agent's
`attach` carries shows under it as the kit's `FileChip`, which
`Http.openAttachment` saves to the downloads directory and opens, as in the
mailbox.

## Requests

The console acts as the account the server read for its token (`GET
/v1/identity`, `Omunculus.me`). A request waits on you when you are its
arbiter, whether it was written by an agent or a person; another account's
request shows, but only its arbiter answers it. A request reads as a
QUESTION, DECISION, PERMISSION or REVIEW from its requester for its arbiter
(`Requests.line`), with its step when it is a review with several reviewers.
The four names and their icons (`Requests.marks`) are the same in the pending
queue, the tree badges, the tree counts ("1 review from clerk") and the LOG. One that is for you reads "for you". No kind of account is
named differently from another.

Everything that waits on you is one queue (`PendingQueue`), reachable from every
page of the conversation: a counter under the head, "⚠ 3 PENDING" (on its own
line above the tabs under 700 px, beside them otherwise), and ANSWER (Alt+R)
open it as a panel over the right of the page, over all of it under 560 px. It
is headed "PENDING · 3" with a close button, says "Oldest first, answer in any
order. Each one names what it unblocks.", and lists the requests waiting on
you, oldest first, one item each (`Pending.queue`; a request another gathers
from below is not a second item). The counter is hidden while nothing waits.
Acting on an item removes it and leaves its sentence in the chat; the panel
stays open on the rest, and closes by itself when the last one is answered:
it never opens, or stays, empty (ANSWER and the counter do nothing while
nothing waits). Esc, the close button and a click outside close it. The
keyboard starts in the first item's first field, or on its recommended
action, and the item shows from its top. The items are held by value
(`pendingJson` of `PagesView`), so a refresh that changes none of them never
rebuilds the boxes being written in.

An item (`RequestDecision`) has four kinds, each with its own icon and
word: QUESTION (a circled question mark), DECISION (a diamond), PERMISSION
(a shield) and REVIEW (a spark). The kind is the request's shape, whoever
decides it: a review when it holds an action, a permission when one of its
options grants, a decision when it offers options, else a question. Its heading is one line: the kind, the time and the item's tools
(copy the question, the "more" menu that holds ESCALATE while it waits on
you, and close where the item opened in place of another, DECIDE INSTEAD), so
nothing overlaps the title at any width. Under it, wrapped inside the item
whatever the width: the request in a sentence (a permission "Surgeon asks to
use the network"; a numbered list "Clerk asks 3 questions"; else the first
sentence of the question, in bold, the rest under it in the regular weight), then the lines ASKS (the asker in their
tone), PATH (the agents from the front desk down to the asker: "front-desk ›
seller › surgeon", from the works the question climbed from), WORK, UNBLOCKS
("surgeon resumes Build: Doce Ana · front-desk and seller are waiting for it"), GRANTS
(a permission: what it lets the agent do, "use the network · this work only")
and, for a review with several reviewers, STEP "2 of 3" (`Pending.describe`). Its question shows once, as its asker wrote it;
one passed up has a chip naming through whom, in order, that opens the
wordings of each level and the harness's own sentence.

The actions are one group (`ActionGroup`) under a hairline at the item's
bottom, wrapping inside the item, never loose chips above the composer: for a
question, a box for the answer and ANSWER (dim until there are words) beside
"I CAN'T ANSWER THIS", which tells the team so in a plain reply; for a
decision, one button per option, with a cancel last; for a review, APPROVE
as the main action (solid), EDIT and DENY: EDIT opens the box, captioned WHAT IT
WILL DO INSTEAD and filled with the text the action would have (a question's
words, a comment's body, an attachment's note; empty for a tool or a grant,
which take a note), and SEND EDIT lets the action go ahead with the words in
place of that text; DENY gives its words as the answer the actor receives (a
review cannot be escalated); for a permission,
GRANT · THIS WORK ONLY as the main action (solid), DENY, and ALWAYS…, a menu
(`AlwaysMenu`) of the scopes saved in the project settings — FOR <AGENT>, IN
THE <STAGE> STAGE, IN FOLDER <name> or IN THE PROJECT — under the heading
SAVED IN THE PROJECT SETTINGS; one pick saves it. An option's label is whole
even when what it names is unknown (`Requests.optionLabel`: "FOR THIS AGENT",
"IN THIS STAGE"). A note to a decision, or the reason of a no, is behind ADD A
NOTE (or ADD A REASON OR A NOTE) and goes with the option chosen; DENY gives
it as the reason. ESCALATE, from the menu, shows the box, captioned WHY IT GOES
UP, and turns the action into ESCALATE; ANSWER INSTEAD turns it back. Sending
shows your answer dimmed under SENDING…; answered, the item shrinks to the
question and your answer; a failure reopens it with your words kept and an
error line. The words are written in the kit's `TextBlock`, one line tall and
growing with its text, and Enter sends them on a question. Under a decision
that gathers only one, the buttons carry no caption of their own.

The title of an item is its own sentence; the work it concerns is the
origin's when the harness passed it up.

`QuestionForm` puts "N OF M ANSWERED" under the item's title, and SEND (off with "answer at least one to send" beside it; solid once one is answered) and a quiet "I CAN'T ANSWER THIS" at the end of the form, after the last item. The
form grows in the queue. While
that end is below the view, the two float on the view's bottom edge over the
card's fill and a hairline, with what passes under them fading out above, with "N MORE QUESTIONS BELOW" at the right
(above them under 520 px) while items start under them; the chip brings the
first of those into view with the keyboard in its box; the last box scrolls into view with the asker's closing paragraph. The form's dim words use the card's lifted dim tone. Each item is its
number, its question wrapped in sentence case at a 620 px measure and a box
(`TextBlock`) as wide as the card's text that grows with its text, with the toggle chip "I DON'T
KNOW YET" under it, which fills the box and, switched off, restores what was
typed. Enter moves to the next box that can take the keyboard (it stays in
the box when none can), Enter in the last and Ctrl+Enter in any send, and the
item whose box takes the keyboard scrolls into view above the floating
actions. The form's model is held by value (`formJson` of
`RequestDecision`), and what was typed, with the box the keyboard was in, is
kept in `Omunculus.drafts` by request, so a form rebuilt takes both back. A line continues its item when no blank line precedes it or it is indented; an unindented line
after a blank one ends the list, and the closing paragraph shows after the
last box and is not sent.

While it is pending it has its options as buttons, one filled and the rest
outlined: GRANT · THIS WORK ONLY for a permission, APPROVE or ACCEPT for a
decision that offers one, else the first option that does not say no or ask
for changes (deny, refuse, cancel, stop, problem, changes, adjust, hold, ...;
`Pending.actions`, its `primary`). The API marks no option recommended. A
deny-like option is never filled; a decision whose options all are has none
filled. So are those of
every decision it gathers from below — an origin still waiting whose options
are named, as an escalation keeps a decision's options on its origin — each
under its part name and who asked it, a grant's scopes read for that
origin's asker and work, an option of an origin given through the reply's
`parts`, down to it (the kit's `Requests.choices` and `Requests.answer`).

Every option carries the words of its field: ANSWER replies with them
alone, omitting `option`; DENY gives them as the reason of a no; and, when
it waits on you, ESCALATE (from the item's menu) raises it with them as the
reason through
`POST …/requests/escalate`, as one part named after its asker.

## The tree

The tree page (`TreePage`) lists the conversation's works in the order they
were made, who handed work to whom, every level deep (`Tree.rows`, one
`TreeNode` a row). When the agent that talks with you hands its works to
others, it is the root ("front-desk  Conversation with you", "10 agents",
with its state: WORKING while a run of its own is open, WAITING FOR
PROJECT-MANAGER while a work of the team is open and no run is its own,
WAITING FOR YOU while a question waits on you, IDLE once nothing is open; and
a badge "⇡ surgeon asks you 1 question" while one does). A badge says whom a
request is, with its icon, in the words of the cards: QUESTION, DECISION, PERMISSION or REVIEW,
then its chain of requesters up to its arbiter ("QUESTION · seller › you").
Each work sits under the
work that handed it down, one level further right; an elbow line joins it to
its parent, and a line goes on down a level's column while rows of it follow,
as in a file tree. The lines are in the faint ink, never coloured.

From 640 px of room beside its indent, a row is four columns:

```
WORK                                         STAGE            STATE                    ELAPSED
● front-desk  Conversation with you                           ⧖ WAITING FOR PROJECT-MANAGER  47 min
└─▾ project-manager  Website for Doce Ana    ●─●─●─◉─○        ⧖ WAITING FOR ADMINISTRATOR   47 min
    │  44 steps · US$ 1.20  4/5 build
    ├─ seller  Website for Doce Ana: sale    ●─●─●─●          ✓ DONE                         6 min
    └─▾ administrator  Build website         …                ⧖ WAITING FOR DESIGN-REVIEWER  31 min
        └─ design-reviewer  page: contact    ●─◉              ✦ WORKING                      29 min
```

Its WORK holds the mark — a chevron while it handed works down, else a dot
in its agent's tone — the agent in that tone, the title, and under them its
what it does now while it works, its own steps (tool calls) and its branch's
cost once the provider priced it (tokens are the cost page's, not the
tree's), and, while it is folded, what it handed down ("3 sub-works, 1 working, 2 done"); short of room these give way
a part at a time. Its STAGE is a track (`StageTrack`) of its workflow's
stages, one dot each: done filled in the success tone, the current one in the
accent with a ring, those to come hollow, with "4/5 build", the step and the
stage, under it; a work in no workflow has none. Its STATE is an icon and a
word: WORKING (with "· ROUND 3" once it was sent back), WAITING FOR and the
agents it waits for — a parent whose children are open says so, never
"working" — WAITING FOR YOU, DONE, FAILED, CANCELLED, STOPPED or UP NEXT
(`Tree.stateOf`). A parent whose child's question climbed to you says
WAITING FOR YOU too, as the progress does. Its ELAPSED is how long it took
once done, else since it was made. Under 640 px, the title goes under the
agent and the stage track and the state go under the title; the time ends the
agent's line. A badge per request between a work and others shows its climb
(`⇡ surgeon › administrator › project-manager › front-desk › you`, in the
warning tone when it is to you; `⇣ 1 review from designer`); it goes to the
other end of the request, lights both rows and opens the request in the
detail.

A click on a work, or Enter, opens its runs inside it (the runs `WorkRuns`
lists, newest first, one line each: the local time it started, the agent, how it
ended and how long, DETAIL at the right), with DETAIL and LOG under them; the
picked or opened row is washed, never framed, and the tree's rail of its mark
ends at the mark; a second Enter, or DETAIL, opens the work in full.
What shows opens itself by what is going on: a work with a work still open
below it shows its works, and so does a root, the rest folded behind their
chevron. A click on a chevron, or → and ←, unfold and fold; what you unfolded
or folded stays so while the page is open. Picking a work from elsewhere — a
badge, OPEN IN TREE, the detail's way down — opens the works above it.

Chips keep the works that need you or work, and `/` filters by title, agent
or stage; a filter keeps the works above each it keeps and shows them all
unfolded. The chips' counts are of works, folded ones included; ALL names its
unit ("ALL 12 WORKS"). ↑ and ↓ move from row to row; → unfolds a folded work,
else goes to the first row under it; ← folds an unfolded one, else goes to its
parent; the keyboard's row has the focus ring.

The work picked shows in full (`NodeDetail`), as a page over the tree, BACK
or Esc returning to the same row. Its header strip names its
agent, title, round and state, with its action at the right: ANSWER, in
the warning tone, while it or a work below it waits on you, which opens the
decision (`decide` for the page to open `RequestDialog`), else OPEN THREAD;
then LOG, and behind "more" ESCALATE, while it asked
you something, and MARK READ, while it left you notes. Under it are its way
down (`Breadcrumb`), its stages and the tabs OVERVIEW (what it does now and
did last, a send-back or a stop and why, whom it waits on and who asks it,
its team with their portraits, each stage's time, its branch's totals, and
the work itself: goal, workspace, where it came from, what it asked and the
notes it left you), THREAD (what its agents said and did, with a composer
to write to its agent or leave it a note), REQUESTS (what it asked and what
it is asked, each with the way it climbed, to answer in place), CHANGES,
RUNS and LOG; `[` and `]`, or ← and → on the tabs, move between them.

- RUNS, the work's runs as `runs` sums up the project's last closed ones,
  matched by id with the snapshot's, one line each — when it started, how it
  ended (RUNNING, ENDED, STOPPED WITHOUT END, with its failed calls counted) and
  how long — with the runs, failed calls and cost in all above them; DETAIL on
  a line shows the run call by call, with its calls, failures and what its
  model used (`runs --run`, Esc back), and the prompt each run was given
  (`prompt --run`);
- CHANGES, the files its calls changed (`changes --work_id`) or, with DIFF,
  their unified diff, added and removed lines coloured, or why there is
  none, as the project not recording changes. REVERT, shown to a member
  holding `project.manage_config` (`GET /capabilities`), asks first and then
  puts the work's files back as they were before it, removing those it
  added, in the workspace the work ran in and under that workspace's write
  rules (`POST /works/{id}/revert`). It restores nothing when a file changed
  since the work's last change to it or is not writable there, and says
  why.

## Pages

The window opens on its start, clean: the project's name and "What now?", then
the ways in as cards, centred, with the masthead's ⓘ opening the keys dialog.
Each card (`StartCard`) has the way's name, one line of what is there, its
number and a chevron; the first is filled in the accent, the one filled action
of the screen. On a project: 01 NEW CONVERSATION ("Say what you need; it goes
to front-desk unless you choose another", the default agent's name, or "Say what
you need and choose who gets it" without one), 02 CONVERSATIONS ("16 conversations · 13 need you ·
1 working", as `Projects.meta` words it), 03 BOARD and 04 PROJECTS. The digits
open them, as a click does, and Enter opens the first; they are keys of this
screen only. On the registry alone, the masthead says READY, or READING while
a project is read: 01 PROJECTS ("3 projects · open one to see its
conversations") and 02 BOARD. Under the cards, in the warning tone, each project
where conversations need you, "agency · 13 need you", a link that opens
that project's conversations with NEEDS YOU lit; until every project is
read the line says "reading what waits for you…" instead. When the server does
not answer, the cards are disabled and a line says so. Entered by one of them, its pages (`PagesView`) are in three levels
(`level`), only those of the level on screen showing.

The registry's level:

- PROJECTS (`ProjectsView`, `ProjectsTable`), every project of the
  registry, under a rule of its state (NEEDS YOU, WORKING, FAILED, IDLE,
  NOT REACHABLE, READING), each row two lines at every width, with no
  header: its id, `· OPEN` after the one the window is on, and its state at
  the top right: NEEDS YOU, WORKING (behind a spark icon), ✕ FAILED (in the error
  tone, while a conversation of it failed and none needs you or works), IDLE, NOT REACHABLE when its
  socket did not answer, or READING… until its conversations are read.
  Under it, dim, as much as fits, never cut: "16 conversations · 13 need
  you · 1 working · 2 failed · Today 22:22", with the last activity (the newest
  conversation begun or work changed); the working goes first, then the last
  activity, then the conversations shorten to "16 conv." (`Projects.meta`).
  The search line (`/`) searches the ids; the chips ALL, NEEDS YOU and
  WORKING, shown while a project is in either state, keep those, on one
  line that scrolls sideways (`ChipStrip`); NEEDS YOU reads in the warning
  tone while it counts any. A list the filters empty offers CLEAR FILTERS.
  Enter or a click opens the project at its conversations; ↑ on the first
  row goes back to the search. The view's `readout`, "3 PROJECTS", counts
  the projects, and reads "1 OF 3 PROJECTS" while a filter or search narrows
  the rows listed;
- BOARD, the works of every project.

The project's level:

- CONVERSATIONS (`HistoryView`, `ConversationsTable`), the project's: those
  needing you first under NEEDS YOU, the one waiting longest first, then the
  others under a rule of the day each began, newest first; filtered by
  their state (chips NEEDS YOU, WORKING, NOT STARTED; ALL lists every one)
  and by their titles and what was first said in them, which it opens from.
  Each row is two or three lines at every width, with no header; a line too
  long for its room ends at a word, with an ellipsis, never mid-word
  (`DecodeLabel`'s `byWords`, on every table). Its title
  is its first work's, else what was first said, with its state at the top
  right: what waits on you ("2 REVIEWS", "7 QUESTIONS", "A DECISION", "A
  PERMISSION", joined when several do), NOT STARTED (nothing was said), WORKING, DONE (every work done or cancelled),
  ✕ FAILED (in the error tone; the last run ended in an error) or IDLE; each
  state has its icon before the word (a warning sign, a spark, a check, a cross). Under it, dim:
  "waiting since 22:43" while something does, whom it is with and the agent
  its first work is with at its stage ("with front-desk › project-manager · design 2/4",
  or "with front-desk · sale 1/4" when they are the same; read from the
  project's works, which the window follows while entered), then since when
  it waits, else "began Today 21:59" ("Yesterday 21:59" or "03 Nov 21:59"). The third line quotes what the newest request asks, or, under a
  work's title, what was first said. Each row's `⋯` opens the conversation
  at its TREE or its LOG instead of its chat. A list the filters empty
  offers CLEAR FILTERS; ↑ on the first row goes back to the search. The
  view's `readout`, "16 CONVERSATIONS", counts the project's conversations and reads
  "14 OF 16 CONVERSATIONS" while a filter or search narrows the rows listed;
- BOARD, the same board, opened kept to the project's works, every
  project's one click away.

A conversation's level, in place of the project's once one is opened:

- CHAT, the chat with the root agent, its progress and its composer;
- TREE, the conversation's works in the order they were made, each with its stage
  track, its state and how long it has run, and the work picked in full. Its
  SHOW IN LOG opens the LOG kept to that work, and BACK returns;
- LOG, every event one line: when (local, `hh:mm:ss`), its kind in a word
  ("question", "decision", "permission", "review", "step", "reply", "passed up",
  "released"; a review has the review's spark icon), what it
  says as one plain sentence ("sales asks you 5 questions: …", "seller wants to
  ask … · for you", "released: ask …", "passed 5 questions up"; an event an
  approved review let go ahead ends "· released by review #<id>"; the
  event's raw type, JSON and milliseconds only in its card), who, and FAILED,
  RETRIED or NEEDS YOU at the right (NEEDS YOU only while that question is
  still open), under rules naming the day and each run. A failed event, such as a run
  that ended in an error, shows the warning icon in the error tone, not its
  kind's own.
  A call reads in plain words ("read design/rounds.md", "looked in design/",
  "looked at design/README.md", "ran a command on quotes/", "could not read
  design/rounds.md: permission denied"), never by its tool name; a command
  is worded by the files it touches, named relative to the workspace (never a
  header or a URL; a glob reads "the .html files in site/"), and its raw line is in the row's card; a
  failed command gives the last line of its output as the reason; a failure
  a later call of the same tool settled is dim with RETRIED, not red; a lookup that found nothing is dim ("found no
  quotes yet"), not FAILED. An answer names whom it answers ("answered
  seller: …", "chose grant for clerk") and leaves out the request ids the agent
  echoed. Plumbing (a run's start and end, hooks, replies without text, an
  answer passed down a level on its way to the one asked, and a call whose
  result has a row of its own, such as a note, a question or a grant) is dimmer and hidden until BEHIND THE SCENES is on. A search line, the chips NEEDS YOU,
  FAILED and BEHIND THE SCENES, each with its count over every row ("NEEDS YOU
  1"), and an agent picker filter it, on one line that scrolls sideways
  (`ChipStrip`); under them, on one line (shorter under 420 px: "30 OF 44
  EVENTS · 14 HIDDEN"), the count of rows, "4 OF 6 EVENTS · 2 BEHIND THE SCENES HIDDEN" while a
  filter keeps rows out and the plumbing is among those it hides, and a
  "more" menu with COPY, the event picked or else the rows shown. Under
  560 px a row is two lines instead of columns: its time, kind, who and
  status, then what it says, in up to three lines. The kind column holds the
  longest kind whole, and a line names what it is about: an artifact by its
  title ("saved Proposal, version 3"), a work by its title ("Doce Ana: design
  preview is now done"), a call as a verb and its object, never a command. The event opened shows in a card
  under the list, with its local time and the server's ISO stamp as UTC and
  its copy and close tools at the top right;
- COST, what the conversation used (`CostView`): a header strip with the
  model calls and the tokens read by the model (with those from cache) and
  written in all, and the cost at its right; then a row per agent, the
  busiest first, its replies, tokens read and tokens written in columns, or,
  under 700 px, on lines of their own so none is cut, and its cost at the top
  right, "-" when its provider reported none. When the provider sends no
  price, one kicker, NO PRICE REPORTED, says so and the cost column and figure
  are left out;
- ARTIFACTS, the documents agents made in the conversation (`ArtifactsView`),
  read from `GET .../artifacts` each time the page opens: a rule per artifact
  headed by its title, the artifact's name without its id and extension, and
  what it is ("Proposal · document"), and a row per version under it, oldest
  first, with its size, by whom and when it was written; the media type is in a
  row's tooltip.
  Enter on a version saves it to the downloads directory through the versions
  route and opens it, as an attachment is. A conversation without one says so.

A work's thread also opens as a page of the chat, from a sub-work block's
OPEN or the progress: the way down to it (`Breadcrumb`, "Conversation ›
Bakery website › Home page", each crumb going back up, the first to the
chat), its transcript and a composer to its agent. The masthead's menu has
OPEN IN TREE (Alt+O), the tree page with the work picked, and ITS LOG.

The log, the tree, the cost and the artifacts are loaded when first on screen and let go
after it, so a closed page costs nothing; the work picked on the tree page
is kept meanwhile.

## The board

The board (`BoardView`) is a kanban, a column per state: open, waiting on a
child, a request or your next message, broken (waiting with nothing named,
for its parent to decide), done and cancelled, the latest changed first.
Each column opens with a rule of its state and how many works it holds,
what the state means on hover.

Each card (`BoardCard`) is framed as a list row: the work's title, and at
the top right its age, or RUNNING behind a spark icon while an agent runs on it
(its border lit then); under it, behind a dot in its agent's colour, the
agent, the project, in a workflow the stage it is at of how many, and
waiting what on; then its conversation and the work it came from. A work
done or cancelled steps back.

BY STATE (Alt+S), BY AGENT (Alt+A) and BY PROJECT (Alt+J) cross the columns
with a lane of each, opened by a rule of its name (an agent's in its colour)
and count. `#project` chips keep one project, and the filter line (`/`)
filters by title, project, conversation, workflow, stage or agent. The
arrows move across and down the columns, and Enter or a click opens the work
on a page of its own. Under 700 px the board is one list (`DataTable`)
instead: each work a row of title, the same lines under it and its age or
RUNNING at the top right, under a rule of its state, and of its lane while
grouped. Opened from the registry's level it shows every project, ALL
PROJECTS lit; from a project's, that project's chip is lit. The chip chosen
holds while the level stays the same. The view's `readout`, "24 WORKS",
counts the works shown.

## A work's page

A work's page (`WorkView`), reached from the board as BACK shows, reads as
an issue. On top are where it is — its project, its conversation, the work
it came from, which opens — and its title.

Under them a header strip says its state, stage and age, with ANSWER, in
the warning tone, while it asked you something (`answer`, for the page to
open the decision), and a tool to its conversation's tree, the work picked
(`openTree`).

On the left are its description, the goal it was given, what it asked and
the notes it left (`WorkSummary`), and under them the tabs RUNS, CHANGES
and PROMPT. Under 700 px its properties stack under them.

On the right are its properties: its state, its project, its workflow with
each stage beside the agent that takes it, those passed checked and the one
it is at lit, or the agent it is with, the work it came from, or you through
the conversation's agent, the works it handed down, each opening on its
page, what comes next — the next stage or whom it reports to — where it
works, and how long ago it began and last changed.

Its bar has BACK alone; Alt+R answers what it asked you and Alt+O opens its
tree. Opening its tree, the window turns to the work's project first when it is
another one (`Omunculus.switchProject`).

## The masthead, the rail and the bar

The masthead names the way to the page in crumbs: PROJECTS or BOARD on the
registry's level; the project, then the page, on a project's; the project and
the conversation open (the title of its first work, else "conversation with
sales", never what was first said, which the chat shows), and on a thread
its work's title, in a conversation, whose tabs name
its page. At the start it names the
project, or, on the registry alone, READY (OFFLINE while the server does not
answer), and the slash after OMUNCULUS shows only before a crumb; under 560 px OMUNCULUS is left out, leaving the
crumbs its room. The project's crumb opens PROJECTS, and the
conversation's its chat. Crumbs that do not fit elide from the left, the
project's never below 8 characters. While a project is open and
conversations need you in the other ones, the masthead's right shows their
count in the notice `2 NEED YOU ELSEWHERE` (`2 ELSEWHERE` under 700 px),
which opens PROJECTS with NEEDS YOU lit, and its × puts it away until the count changes; at the
start and on the registry's level, where the projects' list carries the
count, it does not show.

In a conversation there is no rail and no bar. Its pages are eco's tabs under
its head, `01 CHAT  02 TREE  03 LOG  04 COST  05 ARTIFACTS`, always on one line:
under 420 px they lose their digits, and a strip that still does not fit
scrolls sideways, keeping the chosen tab in view. LOG is marked while a work
failed, and the tabs show once there is more than the chat; the digits and
Ctrl with them choose them as they choose the rail's pages. The masthead's
right has, after the notices, `⋯` and × (up one level, as BACK and Esc do: to
the list the conversation was opened from; on a conversation that has said
nothing, back to where it began). The menu `⋯` holds the page's rarer
actions that the page does not show itself, and NEW CONVERSATION: on TREE,
WRITE TO ITS AGENT and LEAVE A NOTE with a work picked; on a thread, OPEN IN
TREE and ITS LOG. The masthead's OMUNCULUS, while the pages are entered, goes
back to the start from any level. While notes to you are unread, a notice `1 NOTE`
shows the oldest on the chat and marks it read (Alt+M); its × puts it away
until another comes.

On the registry's and a project's levels, as in the studio, the pages of the level are a rail down the left
edge (the kit's `TabRail`) in a fixed order, the one on screen marked in its
place, beside the bar of its commands (the kit's `PageBar`). While the rail
with the pages' names takes at most a fifth of the window's width (from
about 860 px for CONVERSATIONS), it shows them beside their numbers; from
700 px it is folded to their numbers and unfolds as an opaque panel over the
page while the pointer or the keyboard is in it. One click chooses a page and folds the rail, which stays folded until
the pointer has left and come back, and the page takes the keyboard; Esc
folds it too. Under 700 px there is no rail: the bar's page switcher names
the page and lists the five in a menu. The chat, tree, log, cost and artifacts
pages are named so. When the desktop setting `enable-animations` is off, nothing in the
window slides, sweeps or decodes.

The bar ranks the commands — BACK apart, the page's main action solid on the
left (NEW CONVERSATION on CONVERSATIONS, NEW PROJECT on PROJECTS), the
others outlined on the right, BY STATE, BY AGENT and BY PROJECT joined as one
control. When the names do not fit, BACK is only
its chevron and the commands take their short names, then all but the main
one their icons; when even those do not fit, the lowest ranked commands move
into the menu of a `⋯` button.

What the window tells — copied, sent, refused — shows as a toast at its
bottom right, above the composer: information closes itself after a few seconds, an error stays
until closed, and while the server does not answer an error says so until it
answers again.

The window opens at 1080 by 720 px and is at least 360 by 480 px; its
margin is 20 px, 10 px on a window under 560 px tall.

Choosing another page of the level replaces the one on screen, while every
move into another level, conversation, project or a work's thread is
remembered. BACK returns to exactly where it was, its page, level,
project, conversation and the work picked, switching back to the project
it was on, and from the first page entered to the
start, the board keeping its grouping, filter and the card the keyboard was
on. The levels are three — projects, a project's conversations, a conversation — and BACK, Esc and
× go up one: out of a conversation to the list it was opened from, however many
of its pages it went through, so BACK from the list reaches the start. Only a
move down into a conversation's page — a work's thread, a log kept to a work —
is remembered inside it, and BACK returns from it to the page it was opened
from; the tabs are not levels. On the tree page BACK first lets go of the detail page. A conversation that has no message yet is left for where it was opened
from; a page of a conversation is never shown without one. A new
conversation is not a conversation until its first message makes it, so BACK
from its screen returns to where it was opened from, making nothing.

A tooltip shows below its control after 450 ms of the pointer over it, and
never because the keyboard or the program put the focus there. A press, Esc on
the control, or the control being hidden or disabled closes it, and it stays
closed until the pointer leaves and comes back. One shows at a
time.

With `OMUNCULUS_TEXT_AUDIT=1` the window loads the kit's `TextAudit`, which
logs each text drawn out of its box, the window or a clipping item as a
`text-fit:` line.

## Commands by page

- On PROJECTS, NEW PROJECT, which asks for an id and the path of the
  project's config (typed, or picked with PICK FILE) and registers it with
  the server (`POST /v1/projects`, the kit's `NewProjectDialog`); the list
  is read again with the new row picked. It has no key. FILTER (`/`).
- On CONVERSATIONS, NEW CONVERSATION (Ctrl+N, from anywhere entered on a
  project).
- In a conversation, from any of its pages: the pending counter and ANSWER
  (Alt+R) in the header strip, which open the pending queue; the strip's chevron (Alt+P), which opens or closes
  the progress on the chat and puts the keyboard in it; its counts, which
  open TREE and COST; the `1 NOTE` notice
  (Alt+M on the chat); and NEW CONVERSATION (Ctrl+N) in `⋯`. On the tree and a
  work's page a request is also answered in its decision (`RequestDialog`, the
  item over the page).
- On TREE, Alt+R answers the request waiting on you nearest the work picked
  (its own, above it, below it), else the newest, or, with none for you, what
  the work asked, instead of whoever decides. The items of `⋯` answer to
  their chords: WRITE TO ITS AGENT (Alt+W), the composer of its THREAD tab
  writing to its agent, and LEAVE A NOTE (Alt+C), the same composer leaving a
  note (Esc back to writing). Those of the detail's `⋯`
  too: ESCALATE (Alt+E) while it asked you something, which opens the
  decision with Enter escalating, and the notes marked read (Alt+M), all of
  them. Alt+L and Alt+G open its LOG and
  CHANGES tabs, `[` and `]` the previous and next tab, `/` the filter. The
  in-place cards and the note's check still answer and mark one.
- On a work's thread, OPEN IN TREE (Alt+O) and ITS LOG in `⋯`.
- On LOG, `/` filters, and its own `⋯` copies the event picked or else the
  rows shown.
- On BOARD, its groupings (Alt+S, Alt+A, Alt+J) and FILTER (`/`).
- On a work's page, BACK alone; ANSWER in its header strip (Alt+R) and its
  tree's tool (Alt+O).

## Keys and IPC

Typed text never runs a command. The keys are in tiers, one table,
`apps/kit/client/Shortcuts.js`, read by the shell, the pages' commands and
the keys dialog:

- No key of its own: anything that creates, sends, answers, grants, denies,
  escalates, reverts, deletes or cancels is pressed or clicked. Enter in the
  composer and in a request's words send what is written there; no other key
  does.
- Bare keys, for navigation without effect: the digit of a page, `/`, `[`
  and `]` on the tree page, `?`, F1 and Esc, and 1 to 4 on the start screen. They act only while an item to navigate has the keyboard and
  no text field saw a key in the last second (`Typing`, marked by every
  `TextArea` and `TextBox`), so text that lost its field is not taken for
  commands. With nothing holding the keyboard, a printable key does nothing
  but say "Click a field to type"; text is never redirected into another
  field.
- Chords, which a field being written leaves to them: Ctrl and the digit of
  a page, Ctrl+Tab and Ctrl+Shift+Tab for the next or the previous page,
  Ctrl+N for a new conversation, Ctrl+P for the projects, Alt with a
  letter for the commands of a page (R, P, M, O, W, C, E, L, G, F, S, A, J).

The IPC's `start`, `page <name>` (`projects`, `conversations`, `board` and,
with a conversation open, `chat`, `tree`, `log`, `cost`, `artifacts`), `projects`,
`project <id>` (a project of the registry, at its conversations),
`conversations`, `tree`, `log`, `board`, `open <id>`, `work <id>` (a work
of the board, on its page), `newConversation` and `back` move it too, and `send <message>`
sends a message to the conversation open, as the composer does.

`?` or F1 opens a dialog of every key, by where it works
(`ShortcutsDialog`). Esc first lets go of what the page holds — the progress
sheet, the tree's detail page, the log's filter and the event
picked, the board's filter — then goes back as BACK does.
