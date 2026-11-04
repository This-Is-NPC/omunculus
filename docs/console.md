# The console

`apps/console/` is a client of the server, like any other: it never opens
the store or the TOML.

## Requirements and launch

It needs Quickshell, `curl` with WebSocket support and a Wayland session.
`apps/kit/run console` takes the server registry and a project id, which may
be left out when the registry holds one project. `mix omunculus.socket`
resolves the project's socket, and the launcher passes both as
`OMUNCULUS_SOCKET` and `OMUNCULUS_PROJECT`, as it does for every app.

## How it reads the project

The `Omunculus` singleton holds the project as the window sees it and makes
every request through `curl` on the project's local socket. Views only bind
that singleton. The conversation's event stream is `curl` on its WebSocket,
whose frames `EventStream` splits into events. It reads the snapshot again
after each event. Every event is also a row of `eventLog` (`EventLog`, a
`ListModel`), taken at any rate and moved into the rows by a 150 ms timer, so
a burst costs one layout; it is emptied for another conversation. From the
state it derives, soon after each change and every second while a run is open,
the `activity` (`Activity.status`): the team's state, its step and the rows of
the team tree. It keeps when each run started and why it ended (`runStarts`,
from the events), and, for each request being answered, `sending` or `failed`
until the answer is read back.

The theme and the controls more than one app uses are in `apps/kit/ui`, a
copy of eco's overlay, Omarchy's voice session app. Every request goes
through `apps/kit/client`'s `Http`, which finds the scripts beside it. Each
app reaches the kit through its `kit` link to `apps/kit/`, since Quickshell
imports only from within the folder it runs.

## A new conversation

A new conversation starts, on a screen of CONVERSATIONS, by choosing whom it
is with: a card for each agent of depth 0 not only in workflows, with its
portrait (fetched by `apps/kit/client`'s `AgentImages`, which the studio
shares). The conversation keeps the agent its first message named, and
every message names it again.

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

Each agent's turn, in a thread or in the inspector, shows its portrait,
small, beside its name, or its initial in its colour while it has none
(`Portrait`, as on the map's cards and in the inspector); yours shows none.

A note the harness left, as when it stopped a work and tells you so, is no
one's words: it reads NOTE, muted, where a speaker's name would be, as in
the mailbox, and the log names its events' actor `harness`.

What an agent says, a request's reason and a work's goal and notes are the
kit's `Prose`, their web addresses links that open in the browser.

An agent's turn says what it did in plain phrases from the kit's
`Phrases` ("Read 6 files"), never a tool's name; calls that failed are counted
apart, in the error tone, and open to the call and why it failed.

In the main thread a request is a card only while it waits on you. Your answer
reads as a right-aligned bubble (`AnswerBubble`) with the question as one dim
line above it. What the team asked among itself, and a request another
gathers (`Requests.contained`), is not a card: it is one muted `TeamRow`
that opens to the question and the answer, and a stretch of them folds under
a "Team activity" line that shows the last three rows while the team works.
A question for you that arrives while the view follows is held by its top.
Above the composer, `WorkingLine` says from the conversation's `activity`
whether the team works, waits on you or on itself, failed or is done, with the
step and the time; it is hidden when idle. Its SHOW button, while a question
waits on you, brings the question's card into view and puts the keyboard in
its words; a click anywhere else on the line opens the team.

On the chat, the team (`TeamPanel`) toggles beside the thread with T or the
bar's TEAM; in a window under 900 px wide it opens as a sheet over the thread.
Esc in a question's card or in the panel returns to the composer. The bar's
REPLY carries the number of questions waiting on you, and R or REPLY puts the
keyboard in the words of the newest one.

The composer is the kit's `TextArea`: one line that grows with the text up to
eight lines, then scrolls. Enter sends, Shift+Enter breaks the line, and a
pasted text keeps its line breaks.

A message carries the files picked under the composer with the kit's
`FilePicker`, sent through `Http.post`. A file a message or an agent's
`attach` carries shows under it as the kit's `FileChip`, which
`Http.openAttachment` saves to the downloads directory and opens, as in the
mailbox.

## Requests

A request's card (`RequestDecision`) is one of three kinds, named in its
header with who asks and on which work: NEEDS YOU (an answer in words; a
numbered list of questions has a box for each, `QuestionForm`), YOUR DECISION
(a button per option and an optional note) and PERMISSION (the scopes that
grant it, and a no with a reason). Its question shows as its asker wrote it,
in full contrast; one the harness opened, passing on a question an agent left
unanswered, has a line "Passed up by ..." that opens the harness's own
sentence. "I can't answer this" tells the team so in a plain reply, and
ESCALATE sits under MORE. Sending shows your answer dimmed with "Sending...";
answered, the card shrinks to the question and your answer; a failure reopens
it with your words kept and an error line.

While it is pending it has its options as buttons, and so are those of
every decision it gathers from below — an origin still waiting whose options
are named, as an escalation keeps a decision's options on its origin — each
under its part name and who asked it, a grant's scopes read for that
origin's asker and work, an option of an origin given through the reply's
`parts`, down to it (the kit's `Requests.choices` and `Requests.answer`, as
in the mailbox).

Every option carries the words of its field: SEND replies with them
alone, omitting `option`; DENY gives them as the reason of a no; and, when
it waits on you, ESCALATE raises it with them as the reason through
`POST …/requests/escalate`, as one part named after its asker.

## The team and the orchestration map

The team page opens on the team tree (`TeamPanel`): the step the root work
is at and the next one, then a row per work, indented by level, with its
state (icon and word: working, waiting for you, waiting for the team, done,
failed, idle), agent, task, what it is doing and for how long. A team folds
with the chevron or the Left and Right keys, and shows `(+N)` for the rows
hidden. A finished row stays 30 s and then folds into its parent; a failed
one stays. Picking a row shows under the tree what the agent said last, what
it asked and still waits for, and OPEN IN LOG. The rows come from the
window's `activity`.

Below the tree, a line says what runs, what waits and how many are idle,
with a legend, and the map follows.

Requests and unread notes are not in threads: they hang from the work that
made them on the orchestration map, a flowchart on the kit's `FlowCanvas`,
which moves and zooms as the studio's flow does.

You are on top, with a row per depth named at its left. Each work is a card
with its agent's portrait, model, title, state and the tool it calls while
it runs, laid out as a tree, each under the one it came from, parents
centred over their children. Running agents are ringed and their links
flow; idle ones are hollow, smaller, in the dim tone. The map is never
framed below its actual size, so its text keeps its size and the canvas
scrolls. On the map, a card the keyboard reaches comes
into view.

A work that goes through a workflow is a lane instead (`WorkflowLane`), as
the studio's flow draws a workflow: a frame named after it with a card per
stage, in order, each of the agent the setup gives that stage. The stage the
work is at is its live card, those it went through hollow and checked,
those ahead hollow, showing who takes it. The lane is the work's node in the
tree, its parent's link arriving at its frame and its children's leaving
from the stage it is at.

## The inspector

Picking a work opens its inspector: its portrait, for how long it has run
and what it calls now, where it stands in its workflow (`WorkflowTrack`: the
stages in order, those passed checked, the current lit), the work, and its
runs, what it said and did.

Beside WORK, its other sections read the core's tools through
`POST /v1/call`:

- RUNS, the work's runs as `runs` sums up the project's last closed ones,
  matched by id with the snapshot's — how each ended, its calls, those that
  failed and what its model used and cost, a run still open saying so —
  with the runs, failed calls and cost in all above them, each opening call
  by call (`runs --run`, Esc back);
- CHANGES, the files its calls changed (`changes --work_id`) or, with DIFF,
  their unified diff, added and removed lines coloured, or why there is
  none, as the project not recording changes. REVERT, shown to a member
  holding `project.manage_config` (`GET /capabilities`), asks first and then
  puts the work's files back as they were before it, removing those it
  added, in the workspace the work ran in and under that workspace's write
  rules (`POST /works/{id}/revert`). It restores nothing when a file changed
  since the work's last change to it or is not writable there, and says
  why;
- PROMPT, the prompt its last run, or the run opened, was given
  (`prompt --run`), or that it recorded none.

Each scrolls and copies what it shows.

## Pages

The window opens on its start, clean: NEW CONVERSATION (N), CONVERSATIONS
(H) and BOARD (B), and the project's name. Entered by one of them, its pages
(`PagesView`) are in two levels, only those of the level on screen showing.

The project's level:

- CONVERSATIONS, the project's, filtered by what agents do there and what
  was first said, which it opens from;
- BOARD, the works of every project the window's socket lists
  (`GET /v1/projects`), each read on its own socket through `GET /works`
  and kept live by its project stream (`GET /stream`) while the board is on
  screen.

A conversation's level, in place of the project's once one is opened:

- CHAT, the chat with the root agent and its composer;
- TEAM, the team tree and the orchestration map. Its OPEN IN LOG opens the
  LOG kept to that work, and BACK returns;
- LOG, every event a row of a table that filters by text and opens an event
  whole;
- COST, what the conversation used, in all and then by agent, the busiest
  first: model calls, tokens read by the model (with those from cache),
  tokens written and cost. One note says when the provider sends no price
  (`CostView`).

The log, the team and the cost are loaded when first on screen and let go
after it, so a closed page costs nothing; the node picked on the team page is
kept meanwhile.

## The board

The board (`BoardView`) is a kanban, a column per state: open, waiting on a
child, a request or your next message, broken (waiting with nothing named,
for its parent to decide), done and cancelled, the latest changed first.

Each card (`BoardCard`) is the work first — its project, its title, in a
workflow the stage it is at of how many, waiting what on, its conversation
and the work it came from — then, small, its agent's portrait and name and
its age, its border lit while an agent runs on it.

BY STATE (S), BY AGENT (A) and BY PROJECT (P) cross the columns with a lane
of each, chips keep one project, and `/` filters by title, project,
conversation, workflow, stage or agent. The arrows move across and down the
columns, and Enter or a click opens the work on a page of its own.

## A work's page

A work's page (`WorkView`), reached from the board as BACK shows, reads as
an issue. On top are where it is — its project, its conversation, the work
it came from, which opens — and its title.

On the left are its description, the goal it was given, what it asked and
the notes it left (`WorkSummary`, as the map's inspector has them), and
under them its RUNS, CHANGES and PROMPT.

On the right are its properties: its state, its project, its workflow with
each stage beside the agent that takes it, those passed checked and the one
it is at lit, or the agent it is with, the work it came from, or you through
the conversation's agent, the works it handed down, each opening on its
page, what comes next — the next stage or whom it reports to — where it
works, and how long ago it began and last changed.

Its bar has REPLY (R) while it asked you something and OPEN IN MAP (O), its
conversation's map with it picked. The window turns to the work's project
first when it is another one (`Omunculus.switchProject`).

## The masthead, the carousel and the bar

The masthead names the page: the project, then the conversation open (the
title of its first work, else what was first said in it) and its page, or the
page. As in the studio, the pages of the level are a
rail down the left edge (the kit's `TabRail`) in a fixed order, the one on
screen marked in its place, beside the bar of its commands (the kit's
`PageBar`). The rail is folded to the pages' numbers; a window at least
1100 px wide always shows their names, a narrower one unfolds the rail as
an opaque panel over the page while the pointer or the keyboard is in it.
One click chooses a page and folds the rail, which stays folded until the
pointer has left and come back, and the page takes the keyboard; Esc folds
it too. The chat, team, log and cost pages are named so in the rail. The
masthead and the rail show their names as plain text. When the desktop
setting `enable-animations` is off, nothing in the window slides, sweeps or
decodes.

The bar ranks the commands — BACK apart, the page's main action solid (NEW
CONVERSATION on CONVERSATIONS, REPLY where something waits on you, PENDING
on MAP), the others outlined, BY STATE, BY AGENT and BY PROJECT joined as
one control, and FILTER, COPY and FIT as icons at its end. It carries the
readout and shortens the commands' names when they do not fit.

Choosing another page of the level replaces the one on screen, while every
move into another level, conversation or project is remembered. BACK
returns to exactly where it was, its page, project, conversation and the
node picked, and from the first page entered to the start, the board
keeping its grouping, filter and the card the keyboard was on. A conversation
that has no message yet is left for the picker it was made on, or for the
list; a page of a conversation is never shown without one.

A tooltip shows below its control after 450 ms of pointer or Tab focus. A
press, Esc on the control, or the control being hidden or disabled closes it,
and it stays closed until the pointer leaves and comes back. One shows at a
time.

## Commands by page

- On CONVERSATIONS, NEW CONVERSATION (N).
- On CHAT, while a request waits on you REPLY (R), which brings the newest
  question into view and puts the keyboard in its card; TEAM (T), which
  shows or hides the team beside the chat; while a note to you is unread
  MARK READ (M), which brings the oldest into view and marks it read; then
  NEW CONVERSATION (N). Elsewhere a request is answered in its decision
  (`RequestDialog`, the card over the page).
- On TEAM, FIT (F) and, while something waits on you, PENDING, which picks
  it. With a node picked, instead of FIT and PENDING, what applies to it:
  REPLY (R) while it has a pending request, the one waiting on you first;
  ESCALATE (E) while one waits on you, which opens the decision with Enter
  escalating; COMMENT (C) for a work, which puts the keyboard in its
  inspector's composer with Enter leaving a note (Esc back to writing);
  MARK READ (M) while it has notes unread, all of them; and WRITE (W), the
  composer writing to its agent. The in-place cards and the note's check
  still answer and mark one.
- On LOG, FILTER (`/`) and COPY, the event picked or else the rows shown.
- On COST, BACK.
- On BOARD, its groupings and FILTER (`/`).

## Keys and IPC

The digit each page shows, or Ctrl with it, chooses it, and a command's
letter, or Alt with it, runs the command, a field being written keeping its
digits and letters and the picker of a new conversation its digits.
Ctrl+Tab and Ctrl+Shift+Tab go to the next or the previous page.

The IPC's `start`, `page <name>` (`conversations`, `board` and, with a
conversation open, `chat`, `map`, `log`, `cost`), `conversations`,
`agents`, `log`, `board`, `open <id>`, `work <id>` (a work of the board, on
its page), `newConversation` and `back` move it too, and `send <message>`
sends a message to the conversation open, as the composer does.

`?` or F1 opens a dialog of every key, by where it works
(`ShortcutsDialog`). Esc first lets go of what the page holds — the map's
inspector, the log's filter and the event picked, the board's filter — then
goes back as BACK does.
