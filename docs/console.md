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
turns all of it into `projectRows`, one per project, sorted waiting for you
first, then working, then the latest activity, then the id, and
`elsewhere`, the requests waiting for you in the projects the window is not
on.

`switchProject` moves the window to another project: the conversation on
screen closes (its agents go on), and the project's conversations, setup
and capabilities are read once its socket answers. What was typed in the
chat's composer and not sent is kept by conversation (`composerDrafts`) and
comes back when it opens again.

## A new conversation

A new conversation starts, on a screen of CONVERSATIONS, by choosing whom it
is with: a card for each agent of depth 0 not only in workflows, with its
portrait (fetched by `apps/kit/client`'s `AgentImages`, which the studio
shares). Choosing a card makes nothing on the server: the chat opens empty
with that agent, and the first message makes the conversation and then
sends. If making it fails, the words stay in the box and a toast
says so; BACK after a choice returns to the cards having made nothing. The
conversation keeps the agent its first message named, and every message
names it again.

A conversation opened from CONVERSATIONS that has no message yet names no
agent. When several agents of depth 0 may take it, its chat shows the same
cards in place of the timeline and the composer, and the card chosen is the
agent its first message names; Esc goes back. With one, the server names it.

Each card shows the agent's role, the first sentence of its text without a
leading "You are the", and the model it runs on in a tooltip. The first time
no card is chosen and Enter does nothing until one is (a click, its number, or
the arrows and Enter). Afterwards the agent last talked to in the window comes
first, chosen and marked LAST USED; the others follow in the order of the
setup.

## Threads

The console folds the events into threads: the main one, yours with the root
agent, and one per work handed down, where its agent's runs show. A run at
depth 0 belongs to the main thread, a deeper one to its work's.

Each line (`SpeechTurn`) and each agent's turn (`AgentTurn`) is a box under a
heading of its speaker's tone dot, name and time, as in eco: yours on the
right, an agent's on the left tinted with its colour; a line that continues
the same speaker's turn drops the heading. The chat shows no portraits; they
stay in the agent picker and on the team page. A turn's heading says how
long the run has worked: "Working 0:12" while it is open, "Worked 1 min"
after. Once its words are whole, the "more" button beside them, in a gutter
they never take, copies them or shows the log of the run's work (the
thread's `openLog`).

A note the harness left, as when it stopped a work and tells you so, is no
one's words: it reads NOTE, muted, where a speaker's name would be, as in
the mailbox, and the log names its events' actor `harness`.

What an agent says, a request's reason and a work's goal and notes are the
kit's `Prose`, their web addresses links that open in the browser.

Under its words, a turn's tool calls are one group (`ToolCalls`, from the
kit's `Calls.group`). Folded, one line counts them, how many failed and the
first that did: "9 tool calls · 1 failed: next_stage"; how long the run
worked is the turn's to say. While the run is open its last three calls show
live under it. Unfolded, each call is a row with the raw tool name and its args
in brief (`Phrases.brief`: the path of a file tool, whom an `ask` or
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

A work handed down is a block (`SubWorkBlock`) in the thread of the run that
handed it down, where it did; so is a root work a run opened. A card headed
SUB-WORK with its agent, title and time, it says its state, for how long and
how many tool calls, its stages when it has a workflow, and the round with
who sent it back. Choosing it unfolds it in place, indented, into the tabs
01 TRANSCRIPT (the work's own thread, at most 480 px tall with its own
scroll), 02 CHANGES and 03 RUNS; a block two levels down does not unfold.
The open tool at its top right shows the work's thread as a page of its own
(see [Pages](#pages)).

A request is a card only while it waits on you, and it is in the main
thread. Your answer reads as a bubble on the right (`AnswerBubble`) under
YOU ANSWERED and the time, its text left aligned with the line breaks kept
and the bubble as wide as the text, up to 620 px. Above it the question is one dim line at the thread's left
margin, "Asked by SALES: " and its first line with words, cut at 120
characters, with " (N questions)" when it is a numbered list; Enter, Space or
a click opens it in place to its full text. Sending an answer, like sending
a message, takes the view to the end, so it never counts as news; when the
answer comes and the keyboard was in the card, it moves to the composer. A
reply says nothing in the bar when it succeeds; the card shows it. A
question for you that arrives while the view follows is held by its top.

What an agent asks another is an exchange (`TeamRow`) in the thread it was
asked in: "seller asked design-lead · design-lead decides", the question in
its first three lines and, once answered, who answered and what. It is open
while it waits, and DECIDE INSTEAD opens the request's card in place, to
answer it yourself. A request another gathers (`Requests.contained`), as the
lower ones of a question passed up, is not shown on its own.

## The progress

A conversation's pages share its head (`ProgressStrip`), over the tabs. First
a 40 px header strip with its meta — the agent it is with, the stage of the
work in focus, how long it has run, how many agents ran and how many model
calls were made: "SALES · STAGE 2 OF 6 DESIGN · 18 MIN · 4 AGENTS · 212
CALLS", the counts and then the agent giving way as the width shrinks, the
stage shortened to "STAGE 2/6" — and its action at the right: ANSWER, in the
warning tone and with the count when more than one waits, while a question
waits on you, which puts the keyboard in the newest question's card on the
chat; else PROGRESS, once there is a work. Under it, unframed, two lines: the
stages of the work in focus, the newest open root work (`Stepper`: "✓
qualify › ● design · round 2 › ○ assess …", shorter forms as the width
shrinks, down to one dot per stage and the current name), with the chevron
that opens the full view; then who works on it, from its agent down to the
one at work, what that one does and its clock: "seller › design-lead ›
designer: Writing files · 4:12". While a question waits on you that line is
"sales asks you · 1 question"; a finished work says how long it took, and a
team working with no event for ten minutes says so. The two lines are hidden
while no work exists and no agent runs.

The chevron, PROGRESS and Alt+P open the full view, on the chat
(`ProgressSheet`, holding a `ProgressTree`): what waits on you with ANSWER,
then each root work, newest open first, with its title, start and length,
its stages one per row with their agent and time, and under each stage the
works handed down while it was current, nested by level (`ProgressNode`).
An open work is a framed card: its agent and state, its title, its stages,
what it calls, the round with who sent it back and why, the questions it
asked and its tool calls; a done, cancelled or coming one is one line, what
is below it folded. Siblings handed down in one stage are headed "N in
parallel", and the done and cancelled works of each place fold into one
row, "✓ 2 sub-works done · 18 min", unless a question waiting on you
climbed from there. Picking a work shows its agent's last words, its questions in
full, and OPEN (its thread as a page), LOG (the log kept to it) and MAP (the
team page's map, the work picked). ↑/↓ move, → unfolds, ← folds, Enter opens
or folds, Esc returns to the composer.

A work's state follows its questions up their climb. An escalated question
is held by the pending request that gathers it, at any depth
(`Requests.holder`): a work whose question climbed to you needs you, even
when the request now waiting on you belongs to no work, as one an agent at
depth 0 escalated; one whose question an agent holds waits on that agent. A
question for you counts for the deepest work it climbed from
(`Requests.works`). A work waiting for an answer that is not read yet says
"Waiting for an answer". The works above one that needs you keep their own
state, and a done or coming one there is not folded.

Where it opens depends on the window's width: from 1100 px it is docked
beside the thread, 380 px wide and the page's height, and open from the
start once the conversation has a work; from 700 px it is a card under the
strip, pushing the thread down, at most 55 % of the chat's height and
scrolling inside; under 700 px it is a sheet over the whole chat, headed
‹ CHAT, PROGRESS and a close button, which Esc closes. Below 1100 px it starts
closed.

Alt+R, as ANSWER, puts the keyboard in the words of the newest question
waiting on you, from any page of the conversation. Esc in a question's card
or in the progress returns to the composer.

While a decision waits on you, numbered quick chips sit over the composer:
the options of the newest one (`Omunculus.deciding`, from
`Requests.choices`, without the grants saved for good, which are chosen on
its card), then PROGRESS: "1 ADJUST  2 APPROVE  3 PROGRESS". Pressing an
option, or Alt and its number, decides it, without words. On a window under
560 px tall the chips are hidden; their chords still answer.

The composer is the kit's `TextArea` in a frame with a chevron: one line that
grows with the text up to eight lines, then scrolls. Enter sends, Shift+Enter
breaks the line, and a pasted text keeps its line breaks. SEND shows the
trace while the agent written to works, and still sends. Under 420 px its
buttons show their icons only.

The clip in the composer's frame picks files for the message, which show
over the box as chips (the kit's `FilePicker`, a click takes one off) and
are sent through `Http.post`. A file a message or an agent's
`attach` carries shows under it as the kit's `FileChip`, which
`Http.openAttachment` saves to the downloads directory and opens, as in the
mailbox.

## Requests

A request's card (`RequestDecision`) is built as eco's answer card. Its
heading names the kind, who asks and on which work, and the time, on two
lines when the card is under 520 px, with its tools at the top right: copy
the question, the "more" menu that holds ESCALATE while it waits on you, and
close where the card opened in place of another (DECIDE INSTEAD). Its kinds:
NEEDS YOU (an answer in words; a numbered list of questions has a box
for each, `QuestionForm`), YOUR DECISION (a button per option and an optional
note) and PERMISSION (the scopes that grant it — THIS WORK ONLY, FOR
<AGENT>, FOR ITS LEVEL, IN THE <STAGE> STAGE, IN FOLDER <name> or IN THE
PROJECT, and ALWAYS · SAVED
IN THE PROJECT SETTINGS — and a no with a reason). Its question shows once,
as its asker wrote it, in full contrast; one passed up has a chip naming
through whom, in order, that opens the wordings of each level and the
harness's own sentence. Its actions sit at its bottom left: its options,
SEND while words are written, "I can't answer this", which tells the team so
in a plain reply, and DENY last. ESCALATE, from the menu, turns the words
into the reason it goes up and the action into ESCALATE; ANSWER INSTEAD
turns it back. Sending shows your answer dimmed under SENDING…; answered,
the card shrinks to the question and your answer; a failure reopens it with
your words kept and an error line. The words are written in the kit's
`TextBlock`, one line tall and growing with its text.

The header's title is the conversation's subject (`Omunculus.subject`, as in
the masthead: the first root work's title, else the first message), or the
work of the question's origin when the harness passed it up.

`QuestionForm` puts "N OF M" answered in the card's heading, and SEND and
"I CAN'T ANSWER THIS" at the bottom of the card, after the last item. Each
item is its number, its question wrapped in sentence case and a full-width
box (`TextBlock`) that grows with its text, with the toggle chip "I DON'T
KNOW YET" under it, which fills the box and, switched off, restores what was
typed. Enter moves to the next box that can take the keyboard (it stays in
the box when none can), Enter in the last and Ctrl+Enter in any send, and a
box that takes the keyboard scrolls into view without changing whether the
thread follows its end. The form's model is held by value (`formJson` of
`RequestDecision`), and what was typed, with the box the keyboard was in, is
kept in `Omunculus.drafts` by request, so a form rebuilt takes both back; the
thread keeps two views of entries each way, and a box taking the keyboard
never makes its entry the thread's current one. A line continues its item when no blank line precedes it or it is indented; an unindented line
after a blank one ends the list, and the closing paragraph shows after the
last box and is not sent.

While it is pending it has its options as buttons, and so are those of
every decision it gathers from below — an origin still waiting whose options
are named, as an escalation keeps a decision's options on its origin — each
under its part name and who asked it, a grant's scopes read for that
origin's asker and work, an option of an origin given through the reply's
`parts`, down to it (the kit's `Requests.choices` and `Requests.answer`, as
in the mailbox).

Every option carries the words of its field: SEND replies with them
alone, omitting `option`; DENY gives them as the reason of a no; and, when
it waits on you, ESCALATE (from the card's menu) raises it with them as the
reason through
`POST …/requests/escalate`, as one part named after its asker.

## The team

The team page (`TeamView`) shows the works of the conversation a level at a
time, under a breadcrumb ("Conversation › Bakery website › Design
preview"), each crumb going back up. A level is a work's own row, then the
works it handed down, a row each, under a rule naming the stage that handed
them down and, when several run side by side, "2 in parallel · 1 working";
the conversation's level is its root works, the one root's own level when
there is a single one, the roots done before an open one folded under "N
done earlier". The done and cancelled works of each stage, or of a work
without a workflow, fold into one rule, "✓ 2 sub-works done · 18 min" (and
"· 1 cancelled"), which a click, Enter or → unfolds into their rows and ←
folds again; it stays folded while the conversation waits on you, unless
the question climbed from there.

A row (`ProgressNode` in full) is a table row: the work's title with its
state at the top right, a meta line of its agent, its stages (`Stepper`;
under 700 px a track filled to the stage it is at, and that stage) and its
branch's works below, time, calls and cost, and a badge per request
between it and others. A row with works below it has a tool at its right
that goes down to them. The keyboard's row has the focus ring. Chips keep
the works that need you or work, with the works above them, and `/`
filters by title, agent or stage; a filter shows a done row only on the
way to a work it keeps. The chips' counts are of works, folded ones
included. A waiting badge (`⇡ waiting for you`, lit, the one to answer;
`⇡ waiting for design-lead`; `⇣ 1 question from designer`) goes to the
other end of its request, lights both rows and opens the request in the
detail; `⇣ needs you below`, on the works above one that needs you, does
the same with that work's question.

The work picked shows in full (`NodeDetail`). Its header strip names its
agent, title, round and state, with its action at the right: ANSWER, in
the warning tone, while it or a work below it waits on you, which opens the
decision (`decide` for the page to open `RequestDialog`), else OPEN THREAD;
then LOG and, from 900 px, MAP, and behind "more" ESCALATE, while it asked
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
  matched by id with the snapshot's — how each ended, its calls, those that
  failed and what its model used and cost, a run still open saying so —
  with the runs, failed calls and cost in all above them, each opening call
  by call (`runs --run`, Esc back), and the prompt each run was given
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

From 1100 px the outline and the detail sit side by side, the focus work
picked at first. Narrower, the outline takes the page and the detail opens
as a page over it; BACK or Esc returns to the same row.

From 900 px OUTLINE and MAP, a chip group at the right of the search line,
switch the outline for the map (`AgentsView`, on the kit's `FlowCanvas`,
which moves and zooms as the studio's flow does), remembered while the
conversation is open. You are on top; each work is one card (`AgentNode`):
the portrait and name of its agent, its state, title and stages, and its
waiting badges, its children under it grouped by the stage that handed them
down. Only the requests of the work picked are drawn, from the asker to
whoever decides; agents with nothing to do show only with SHOW IDLE AGENTS.
The map is never framed below its actual size; the canvas scrolls. The work
picked shows in the same detail, beside the map.

## Pages

The window opens on its start, clean. On a project: NEW CONVERSATION (N),
CONVERSATIONS (H), BOARD (B) and PROJECTS (P), keys of this screen only,
and "Project agency · its agents wait for a word". On the registry alone:
PROJECTS and BOARD, and "3 projects · pick one to talk with its agents".
When the server does not answer, the ways in are disabled and the line says
so. Entered by one of them, its pages (`PagesView`) are in three levels
(`level`), only those of the level on screen showing.

The registry's level:

- PROJECTS (`ProjectsView`, `ProjectsTable`), every project of the
  registry, under a rule of its state (NEEDS YOU, WORKING, IDLE, NOT
  REACHABLE, READING): its id, `· OPEN` after the one the window is on, its
  conversations and open works (not done or cancelled), its last activity
  (the newest conversation begun or work changed, "Today 22:22") and its
  state: WAITING FOR YOU and how many, WORKING and how many, IDLE, NOT
  REACHABLE when its socket did not answer, or READING… until its
  conversations are read. The search line (`/`) searches the ids; the chips
  ALL, WAITING FOR YOU and WORKING, shown while a project is in either
  state, keep those, on one line that scrolls sideways (`ChipStrip`). A
  list the filters empty offers CLEAR FILTERS. Enter or a click opens the
  project at its conversations; ↑ on the first row goes back to the search.
  The conversations cell says as much as fits, never cut: "15 conversations
  · 14 open works", "15 conversations · 14 open", "15 conversations", "15
  conv.", then "15" (`Projects.conversationsText`). Under 700 px a row
  stacks: the id, then its conversations and last activity, its state at
  the top right; the last activity goes before the conversations would
  shorten past "15 conversations". The view's `readout`, "3 PROJECTS",
  counts the rows listed;
- BOARD, the works of every project.

The project's level:

- CONVERSATIONS (`HistoryView`, `ConversationsTable`), the project's, under
  a rule of the day each began, newest first, filtered by what agents do
  there and by their titles and what was first said in them, which it opens
  from. A row's title is its first work's, else what was first said; under
  it, the agent that work is with, when it began ("Today 21:59", "Yesterday
  21:59" or "03 Nov 21:59"), how many works it holds and the stage its first
  work is at (read from the project's works, which the window follows while
  entered). Its state is at the top right: NOT STARTED (nothing was said;
  hidden under ALL, shown by its chip), WAITING FOR YOU, WORKING (behind a
  dot), DONE (every work done or cancelled) or IDLE. Each row's `⋯` opens
  the conversation at its TEAM or its LOG instead of its chat. A list the
  filters empty offers CLEAR FILTERS; ↑ on the first row goes back to the
  search. The view's `readout`, "12 CONVERSATIONS", counts the rows listed;
- BOARD, the same board, opened kept to the project's works, every
  project's one click away.

A conversation's level, in place of the project's once one is opened:

- CHAT, the chat with the root agent, its progress and its composer;
- TEAM, the works of the conversation and the work picked in full. Its SHOW
  IN LOG opens the LOG kept to that work, and BACK returns;
- LOG, every event a table row: what it says, then when (local,
  `hh:mm:ss.zzz`), what kind, who and on which work, FAILED or ASKS YOU at
  its top right, under rules naming the day and each run. A search line, the
  chips ASKS ME and FAILED and an agent and a level picker filter it; the
  count of rows and a "more" menu with COPY, the event picked or else the
  rows shown, sit at the filters' right. The event opened shows in a card
  under the list, with its local time and the server's ISO stamp as UTC and
  its copy and close tools at the top right;
- COST, what the conversation used (`CostView`): a header strip with the
  model calls and the tokens read by the model (with those from cache) and
  written in all, and the cost at its right; then a row per agent, the
  busiest first, its cost at the top right, "-" when its provider reported
  none. One note says when the provider sends no price.

A work's thread also opens as a page of the chat, from a sub-work block's
OPEN or the progress: the way down to it (`Breadcrumb`, "Conversation ›
Bakery website › Home page", each crumb going back up, the first to the
chat), its transcript and a composer to its agent. The masthead's menu has
OPEN IN TEAM (Alt+O), the team page with the work picked, and ITS LOG.

The log, the team and the cost are loaded when first on screen and let go
after it, so a closed page costs nothing; the work picked on the team page,
and whether it shows the outline or the map, are kept meanwhile.

## The board

The board (`BoardView`) is a kanban, a column per state: open, waiting on a
child, a request or your next message, broken (waiting with nothing named,
for its parent to decide), done and cancelled, the latest changed first.
Each column opens with a rule of its state and how many works it holds,
what the state means on hover.

Each card (`BoardCard`) is framed as a list row: the work's title, and at
the top right its age, or RUNNING behind a dot while an agent runs on it
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
open the decision), and a tool to its conversation's team, the work picked
(`openTeam`).

On the left are its description, the goal it was given, what it asked and
the notes it left (`WorkSummary`), and under them the tabs RUNS, CHANGES
and PROMPT. Under 700 px its properties stack under them.

On the right are its properties: its state, its project, its workflow with
each stage beside the agent that takes it, those passed checked and the one
it is at lit, or the agent it is with, the work it came from, or you through
the conversation's agent, the works it handed down, each opening on its
page, what comes next — the next stage or whom it reports to — where it
works, and how long ago it began and last changed.

Opening its team, the window turns to the work's project first when it is
another one (`Omunculus.switchProject`).

## The masthead, the rail and the bar

The masthead names the way to the page in crumbs: PROJECTS or BOARD on the
registry's level; the project, then the page, on a project's; the project and
the conversation open (the title of its first work, else what was first said
in it), and on a thread its work's title, in a conversation, whose tabs name
its page. At the start it names the
project, or nothing on the registry alone, and the slash after OMUNCULUS
shows only before a crumb; under 560 px OMUNCULUS is left out, leaving the
crumbs its room. The project's crumb opens PROJECTS, and the
conversation's its chat. Crumbs that do not fit elide from the left, the
project's never below 8 characters. While a project is open and requests
wait for you in the other ones, the masthead's right shows the notice `2
WAITING ELSEWHERE` (`2 ELSEWHERE` under 700 px), which opens PROJECTS with
WAITING FOR YOU lit, and its × puts it away until the count changes; at the
start and on the registry's level, where the projects' list carries the
count, it does not show.

In a conversation there is no rail and no bar. Its pages are eco's tabs under
its head, `01 CHAT  02 TEAM  03 LOG  04 COST`, wrapping on a narrow window,
LOG marked while a work failed; the digits and Ctrl with them choose them as
they choose the rail's pages. The masthead's right has, after the notices,
`$` (COST), `⋯` and × (back to the conversations; BACK and Esc still return
in history). The menu `⋯` holds the page's rarer actions and NEW
CONVERSATION: on TEAM, AS AN OUTLINE and AS A MAP from 900 px, FIT THE MAP,
WRITE TO ITS AGENT and LEAVE A NOTE with a work picked, ESCALATE and the
notes to mark read; on LOG, COPY THE EVENT or COPY THE LOG; on a thread,
OPEN IN TEAM and ITS LOG. While notes to you are unread, a notice `1 NOTE`
shows the oldest on the chat and marks it read (Alt+M); its × puts it away
until another comes.

On the registry's and a project's levels, as in the studio, the pages of the level are a rail down the left
edge (the kit's `TabRail`) in a fixed order, the one on screen marked in its
place, beside the bar of its commands (the kit's `PageBar`). From 1100 px the
rail shows the pages' names; from 700 px it is folded to their numbers and
unfolds as an opaque panel over the page while the pointer or the keyboard is
in it. One click chooses a page and folds the rail, which stays folded until
the pointer has left and come back, and the page takes the keyboard; Esc
folds it too. Under 700 px there is no rail: the bar's page switcher names
the page and lists the four in a menu. The chat, team, log and cost pages are
named so. When the desktop setting `enable-animations` is off, nothing in the
window slides, sweeps or decodes.

The bar ranks the commands — BACK apart, the page's main action solid on the
left (NEW CONVERSATION on CONVERSATIONS, REPLY where something waits on you),
the others outlined on the right, OUTLINE and MAP, and BY STATE, BY AGENT and
BY PROJECT, joined as one control. When the names do not fit, BACK is only
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
on. On the team page BACK first lets go of the detail page or the level
shown. A conversation that has no message yet, or is not made yet, is left
for the picker it began on, or for the list; a page of a conversation is
never shown without one.

A tooltip shows below its control after 450 ms of pointer or Tab focus. A
press, Esc on the control, or the control being hidden or disabled closes it,
and it stays closed until the pointer leaves and comes back. One shows at a
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
- In a conversation, from any of its pages: ANSWER (Alt+R) in the header
  strip, which brings the newest question into view on the chat and puts the
  keyboard in its card; PROGRESS and the chevron (Alt+P), which open or close
  the progress on the chat and put the keyboard in it; the `1 NOTE` notice
  (Alt+M on the chat); the quick chips (Alt+1 … Alt+9) on the chat; and NEW
  CONVERSATION (Ctrl+N) in `⋯`. Elsewhere than on the chat a request is
  answered in its decision (`RequestDialog`, the card over the page).
- On TEAM, Alt+R answers the request waiting on you nearest the work picked
  (its own, above it, below it), else the newest, or, with none for you, what
  the work asked, instead of whoever decides. The items of `⋯` answer to
  their chords: WRITE TO ITS AGENT (Alt+W), the composer of its THREAD tab
  writing to its agent, and LEAVE A NOTE (Alt+C), the same composer leaving a
  note (Esc back to writing); ESCALATE (Alt+E) while it asked you something,
  which opens the decision with Enter escalating; the notes marked read
  (Alt+M), all of them; FIT THE MAP (Alt+F). Alt+L and Alt+G open its LOG and
  CHANGES tabs, `[` and `]` the previous and next tab, `/` the filter. The
  in-place cards and the note's check still answer and mark one.
- On a work's thread, OPEN IN TEAM (Alt+O) and ITS LOG in `⋯`.
- On LOG, `/` filters, and `⋯` copies the event picked or else the rows shown.
- On BOARD, its groupings (Alt+S, Alt+A, Alt+J) and FILTER (`/`).

## Keys and IPC

Typed text never runs a command. The keys are in tiers, one table,
`apps/kit/client/Shortcuts.js`, read by the shell, the pages' commands, the
picker and the keys dialog:

- No key of its own: anything that creates, sends, answers, grants, denies,
  escalates, reverts, deletes or cancels is pressed or clicked. Enter in the
  composer and in a request's words send what is written there, and a quick
  chip over the composer is chosen by Alt and its number; no other key does.
- Bare keys, for navigation without effect: the digit of a page, `/`, `[`
  and `]` on the team page, `?`, F1 and Esc, the digits of the cards of the
  picker, and N, H, B and P on the start screen. They act only while an item to navigate has the keyboard and
  no text field saw a key in the last second (`Typing`, marked by every
  `TextArea` and `TextBox`), so text that lost its field is not taken for
  commands. With nothing holding the keyboard, a printable key does nothing
  but say "Click a field to type"; text is never redirected into another
  field.
- Chords, which a field being written leaves to them: Ctrl and the digit of
  a page, Ctrl+Tab and Ctrl+Shift+Tab for the next or the previous page,
  Ctrl+N for a new conversation, Ctrl+P for the projects, Alt with a
  letter for the commands of a page (R, P, M, O, W, C, E, L, G, F, S, A, J),
  and Alt with a digit for the quick chips over the composer.

The IPC's `start`, `page <name>` (`projects`, `conversations`, `board` and,
with a conversation open, `chat`, `map`, `log`, `cost`), `projects`,
`project <id>` (a project of the registry, at its conversations),
`conversations`, `agents`, `log`, `board`, `open <id>`, `work <id>` (a work
of the board, on its page), `newConversation` and `back` move it too, and `send <message>`
sends a message to the conversation open, as the composer does.

`?` or F1 opens a dialog of every key, by where it works
(`ShortcutsDialog`). Esc first lets go of what the page holds — the progress
sheet, the team's detail page or level, the log's filter and the event
picked, the board's filter — then goes back as BACK does.
