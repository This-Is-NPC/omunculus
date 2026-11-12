# The screens

Every screen of the three apps, in the order you meet them, with the keys
each answers to. The apps open on a project a running server serves
([how to run the server](how-to-run-the-server.md)); what each app does
underneath is in [console](console.md), [mailbox](mailbox.md) and
[studio](studio.md).

## Pictures

There are no pictures, on any screen. A picture here has to come from a
mise task that drives the real apps against an isolated server seeded with
synthetic, versioned fixtures, named `NN-<what>.png` in `docs/img` in the
order this page walks the screens. There is no such task, for two reasons:

- The apps are Quickshell windows. They need a Wayland session, and no
  task here starts a compositor of its own to draw them apart from the
  desktop of the person running it.
- The screens worth a picture show works, requests, runs and costs. The
  model that needs no network, `fake`, hands no work down and asks
  nothing, so a project seeded through it would show empty pages; fixtures that put a conversation's works and requests in
  the store do not exist.

So each screen below says what it holds in words.

## The console

`apps/kit/run console --config <server.toml> [--project <id>]`, where
`<server.toml>` and `<id>` are placeholders for the server registry and a
project id of it. Without `--project`, a registry of several projects opens
on the registry: the projects and the board.

These keys work on every screen of the console:

| Keys | What they do |
| --- | --- |
| Tab · Shift+Tab | move between controls |
| Enter · Space | press the control |
| 1 · 2 · … | the page of that number: the projects and the board, a project's conversations and the board, or, in a conversation, its chat, tree, log, cost and artifacts; only while you navigate, not a second after typing |
| Ctrl+1 · Ctrl+2 · … | the same, from a field being written |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous page |
| Ctrl+P | the projects, also from a field being written |
| Esc · BACK | let go of what the page holds, then up one level — a conversation, its list, the start; the masthead's OMUNCULUS goes straight to the start |
| Alt + a key of the page | the key, from a field being written |
| ? · F1 | the keys dialog, which lists these tables |

Under 700 px there is no rail of pages: the bar's page switcher names the
page and lists the others, and the commands that do not fit are in its `⋯`
menu. In a conversation there is neither rail nor bar: tabs under its head
choose its pages, and the masthead's `⋯` and × open its rarer
actions and the conversations; its cost is the COST tab. The window is at least 360 by 480 px.

Typed text never runs a command: nothing that sends, answers, grants, denies,
escalates, reverts, deletes or cancels has a key of its own outside a field,
and a key pressed with no field to take it only says "Click a field to type".

The console answers Quickshell IPC too (`quickshell ipc --path apps/console
call omunculus <function>`): `start`, `page <name>`, `projects`,
`project <id>`, `conversations`,
`tree`, `log`, `board`, `open <conversation id>`, `work <work id>`,
`newConversation`, `back` and `send <message>`.

### 1. The start

On a project, its name, "What now?" and four ways in as cards, two by two
(one column on a narrow window), each with
its number and one line of what is there, the first one filled: NEW
CONVERSATION, CONVERSATIONS (how many, how many need you, how many work),
BOARD and PROJECTS. On the registry alone, two: PROJECTS (how many it holds)
and BOARD. Under them, in the warning tone, the projects
where conversations need you and how many, each a way into that project's
conversations with NEEDS YOU lit (a line says it is reading until every
project is). The ⓘ at the top right opens the
keys.

| Keys | What they do |
| --- | --- |
| 1 · 2 · 3 · 4 | the card of that number: a new conversation, the conversations, the board, the projects (on the registry alone, 1 and 2) |
| Enter | the first card |

### 2. Projects

Every project of the server's registry, under a rule of its state (NEEDS
YOU, WORKING, FAILED, IDLE), two lines each: its id, OPEN beside the one the
window is on, and its state at the top right — NEEDS YOU, WORKING, ✕ FAILED,
IDLE, NOT REACHABLE or READING…; under it its conversations, how many need you and
how many agents work in and its last activity.
Under the search line, chips keep those needing you or working. NEW PROJECT
registers another with the server: its id and the path of its config file.
The masthead names the way to every page from here on; the project's name
in it opens this page, and `▲ 2 ELSEWHERE` on its right, while
conversations need you in other projects, opens it with those projects
picked out.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose |
| Enter | open it, at its conversations |
| / | search the ids |
| Esc | back |

### 3. A new conversation

The composer: "TO", a folded control, and the box. No agent is chosen for you:
with a default agent the control says "to Front desk if left empty" and the
server sends an unaddressed first message there. The start card's line says whom it goes to. Opening
TO lists the other agents of depth 0 (opt-in), each with its role, and under
FOR THE PROJECT ITSELF the agents that change how the project works, each
change only once you approve it; picking one replaces the recipient. Without
a default agent TO starts empty, the list is open and SEND waits for a pick.
The conversation is made by the first message, not by the pick, and keeps the
agent that message names.

| Keys | What they do |
| --- | --- |
| Enter · Space · ↓ on TO | open the list |
| ↑ · ↓ | move along the list |
| Enter | on a name, address the message to it |
| Esc | fold the list, then back |

### 4. Conversations

The project's conversations, those needing you first, the longest waiting
first, then the others under a rule of the day each began: its title and
its state at the top right, what waits on you ("7 QUESTIONS", "A
DECISION"); under it since when it waits, whom it is with and which agent
holds its work at which stage ("front-desk · project-manager is at design (2/4)"), when
it began and its tree in a few words ("14 works · 4 levels · 2 open"); then what the newest request asks. Under the
search line, chips filter by state, ALL listing every one; a row's `⋯`
opens it at its tree or its log.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose; ↑ on the first row, the search |
| Enter | open |
| Ctrl+N | new conversation |
| / | search |

### 5. Chat

The chat is the conversation as a lineage stream, read from the top down. What
you said is a filled bubble on the right; what an agent says is a bubble on the
left tinted with its colour, under its name and time, with the message's
subject, when it has one, as the bubble's bold first line. Under the words
come the works, one level of the hierarchy each, joined by lines that run from
a work down to the works it handed down: the agent's dot and name in its
colour, its title, an open arrow and its state as an icon and a word. A work
in a workflow shows its stages under its row, the ones done checked, the one
reached filled, those to come empty. Finished works fold into one line ("2
folded · homepage layout approved · 7 entries") that a chevron unfolds and, unfolded, folds again from the line that stays above
its works; works
that ran at once are a fork, "PARALLEL ×4 · 2 DONE · 2 WORKING", with a card
for each. A request addressed to you is a card under the work that made it,
joined by a dashed connector marked with its level ("L0"), which you answer in
place (see [the cards](#6-the-request-cards)) and fold from its heading; once
answered it stays there as history, with the word of what you did (ANSWERED,
CHOSE, GRANTED, DENIED) and your answer. What the agents asked one another is
one compact line, folded, that opens to the question and the answer. A note
an agent of the team left is an outlined card headed NOTE FROM SELLER. There
are no run rows or tool calls here: they are in a scope, the tree and the log.
While any agent of the team works, a live line at the end of the thread, at
every width, says who, down from the agent you write to, what it does in a
plain verb and for how long. The "N NEW" pill, when the thread runs past the
view, sits above the composer and never over a row. There is no status block
over the tabs: what waits on you is a card in the chat. The tabs are on one
line, without their digits on a narrow window. The composer is a line with a
clip that attaches files and SEND; it has no options of a request above it. A
conversation with no message yet, opened from the conversations, shows the TO
control of [a new conversation](#3-a-new-conversation) over the composer when
several agents of depth 0 may take it; once it is under way, the same line
says whom the message goes to, "TO" and the agent's dot and name, without a
list. In a work's scope it names the work's agent.

A work's open arrow shows the chat kept to that work's branch, a scope: a bar
names the agents from the front desk down to it, with its level, and WHOLE
CONVERSATION goes back; under each work of the branch are its runs with their
tool calls and the notes its agents left. OPEN IN TREE (Alt+O) shows it on the
tree page.

| Keys | What they do |
| --- | --- |
| Alt+R | go to the oldest card that waits on you |
| Alt+M | show the oldest note to you and mark it read |
| Ctrl+N | new conversation |
| Enter, in the composer | send |
| Shift+Enter, in the composer | break the line |

### 6. The request cards

Everything whose arbiter you are, reviews included, is a card in the chat, at
the time it was asked; there is no separate list. A card is one of four kinds, each with
its icon and word: QUESTION, DECISION, PERMISSION or REVIEW. It says what it asks in a
sentence; for a permission, what it grants or, for a review with several
reviewers, its step; every text wraps inside it. Who asks, the way down from
the front desk, the work and what it unblocks are behind a small "details"
chip, closed. A button at the end of the heading collapses the card to one
line (kind, title, "0 of 3 answered", time) and expands it with what you typed
kept; only the newest card waiting on you starts expanded, the older ones and
the answered ones start collapsed. Its
actions are one group at its bottom: a box and ANSWER for a question; a button
per option for a decision, the recommended one (APPROVE or ACCEPT) filled and
the others outlined; GRANT · THIS WORK ONLY, filled, DENY and an ALWAYS… menu of
the wider scopes (for the agent, the stage, the folder or the project, saved
in the project settings) for a permission; APPROVE, filled, EDIT (which opens
the action's text to rewrite and SEND EDIT) and DENY for a review. A note, or the reason of a no, is
behind ADD A NOTE, and the card's "more" menu holds ESCALATE. Acting on a
card keeps it in place without buttons: the word of what you did, the question
and your answer.

| Keys | What they do |
| --- | --- |
| Enter | in an answer's words: send it, or escalate when escalating |

### 7. Tree

The root work's stage path first, as in the chat, then the conversation's
works in the order they were made, who handed work to
whom, every level deep. The agent that talks with you is the root, with its
own state and what it asks you; each work sits under the work that handed it
down, lines joining it to its parent as in a file tree. A row is the work's
mark (a chevron while it handed works down, else its agent's dot), its agent
in its tone, its title, its stage track (a dot per stage, the step of how
many under it), its state in words — WORKING, WAITING FOR the child or agent
it waits for, WAITING FOR YOU, DONE, FAILED, CANCELLED — and how long it has
run; under the title its steps and cost, and a badge for the climb of what it
waits on (⇡ surgeon › administrator › project-manager › front-desk › you) and
what it is asked (⇣). On a narrow window the stage track and the state go
under the title. The paths at work or waiting are open; the rest fold behind
their chevron. Chips keep the works that need you or work, with the works
above them. A click on a work opens its runs inside it, one line each, and
DETAIL opens it in full, as a page over the tree, under a header strip with
ANSWER or OPEN THREAD, in the tabs OVERVIEW, THREAD, REQUESTS, CHANGES, RUNS
and LOG.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | move from row to row |
| → · ← | unfold, or the first row under it; fold, or its parent |
| Enter | show its runs inside it; again, open it in full |
| / | filter the works |
| Alt+R | answer what waits on you nearest the work picked |
| Alt+E | open the decision of what it asked you, to escalate (the detail's `⋯` ESCALATE) |
| Alt+W | write to its agent (`⋯` WRITE TO ITS AGENT) |
BY LEVEL, the first view, groups the rows under a header per level of the
hierarchy ("LEVEL 2 · seller, design-lead · 6 events"), each row's dot in the
column of its level; BY WORK puts them under the row of their work, on the
lifelines of the tree; BY TIME lists them oldest first, a rule naming each day
and each run.

| Alt+C | leave it a note, without a run (`⋯` LEAVE A NOTE) |
| Alt+M | mark its notes read (the detail's `⋯` MARK READ) |
| Alt+L · Alt+G | its LOG and CHANGES tabs |
| Esc | the detail, then the tree, then back |

### 8. Log

Every event of the conversation, a row each, which opens whole.

| Keys | What they do |
| --- | --- |
| / | filter the events |
| Esc | empty the filter, then back to the rows |

Each row is one line: when, its kind, what the event says, who; under 560 px
two lines, the sentence under the rest. Chips, on one line that
scrolls sideways (wrapped onto lines on a narrow window), each with its count, keep
the events that need you or failed, a picker one agent's, and BEHIND THE
SCENES brings back the plumbing (run starts and ends, hooks), dimmed; a rule
names each day and each run. The count, on one line, says how many rows a
filter keeps out, and "2 BEHIND THE SCENES HIDDEN" ("2 HIDDEN" on a narrow
window) when that is why. A failed event has the
warning icon in the error tone. Opened from a work of
the tree, it is kept to that work.

### 9. Cost

What the conversation used, with TOTAL, in dollars, at the top right and, under
the toggle, the model replies and tokens in all. BY WORK is the tree of the
works: each row has the model its agent runs on, the tokens it used, those of
everything below it, and a bar with its branch's share of all the tokens. A work
has tokens and no dollars: the server prices an agent, not a work. BY AGENT is a
row per agent with its model, replies, tokens and cost, in columns or, on a
narrow window, on lines of their own. The dollars are at the price each model
has in the project config; for a model with none a line says "no price set for
haiku in the project config". It has no keys of its own.

### 10. Board

The works of every project of the registry as a kanban, a column per state
under a rule of each; opened from a project, kept to its works, every
project's one chip away. A card has the agent (its dot and name), its level
and the work it hangs under ("level 2, under Sale"), the project and the stage,
its state as an icon and a word, how long since it changed and its conversation. Under 700 px it is one list, the works under a rule
of their state.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | move between the works, across and down the columns |
| Enter · Space | open the work on its page |
| Alt+S · Alt+A · Alt+J | by state, a lane per agent, a lane per project |
| / | filter the works |
| Esc | empty the filter, then back to the works |

### 11. A work

One work read as an issue: where it is and its title on top, then a header
strip of its state with ANSWER and a tool to its team; its
description, goal, questions and notes, then its RUNS, CHANGES and PROMPT on
the left; its state, workflow, agent, parent, children and times on the
right.

| Keys | What they do |
| --- | --- |
| Alt+R | answer what it asked you |
| Alt+O | its conversation's tree, the work picked |
| Esc | back |

### 12. The keys dialog

`?` or F1 opens it on any screen: every key above, by where it works. The
arrows and PgUp/PgDn scroll it.

## The mailbox

`apps/kit/run mailbox --config <server.toml> [--project <id>]`. Its IPC
(`quickshell ipc --path apps/mailbox call mailbox <function>`):
`compose`, `open <key>`, `search <query>`, `fold folders|list` and `reply`.
How it maps a conversation to e-mail is in [the mailbox](mailbox.md).

### 13. The folders

COMPOSE (the filled action while the list is on screen) over the folders, each
with its icon, its name and its count in a box: Inbox (unread threads), Pending
(reviews), Sent, Drafts and Archive. The current one is outlined in the accent.
Beside them, the threads of the folder, newest first, each with its sender,
subject, snippet, label and time; unread ones in bold. An empty folder says
"Nothing here yet" and offers COMPOSE. Pending lists instead the reviews that
wait on you, newest first, each with the agent that acted and what it wants to
do. A command bar holds MARK ALL READ and the search. Each column ends in the
arrow that folds it: the folders to a rail of counts under a plus that
composes, the list to its count. At phone width the folders are pills above the
search and COMPOSE floats at the bottom right of the list.

| Keys | What they do |
| --- | --- |
| Ctrl+N | compose |
| / | search by subject, agent, project, message or file name |
| Esc | clear the search |
| Ctrl+B | fold the folders to a rail |
| Ctrl+L | fold the list to a rail with its count of e-mails |

### 14. A thread

One conversation with an agent of depth 0, stacked oldest first, the latest
message open, with its label in the head. Each open message offers REPLY,
FORWARD and, with several counterparts, REPLY ALL; each opens a
[composer](#15-the-composers) docked over the mailbox, so the thread stays
readable beside it.

A review opened from Pending is a card in the same pane, bordered in the
warning tone and marked REVIEW and WAITING FOR YOU: who acted, what it wants to
do and the text it holds. APPROVE is the filled action; EDIT opens a box with
the held text and sends your words in its place; DENY opens it for an optional
reason; DETAILS shows the arguments as lines and what each answer does.

| Keys | What they do |
| --- | --- |
| Ctrl+R | reply to the latest message |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | minimize the composer in focus; else close the thread |

### 15. The composers

A new message, a reply and a forward are each a composer, a window docked at
the bottom right of the mailbox, over its content, never in its layout. Several
stand side by side, the newest on the right; when there is no room the older
ones become tabs along the bottom edge.

A composer's bar holds its title (the subject, or "New message") and three
buttons: minimize (Esc), which folds it to a tab that keeps what is written and
which a click restores; expand, which shows it large and centred over a dim
backdrop; and close, which asks to save a draft or discard only when something
is written. Under the bar, a label column and one row per field: To (one agent,
as a chip, with autocomplete and the address book; a reply may hold several; it
is one row high and grows only when its chips wrap) and Subject (a single-line
field, empty on a new message and "Re: ..." on a reply, editable on both). Then
the body, which fills the window, MORE for the message a reply answers, and one
footer row: Attach, the files as chips, DISCARD and SEND, the filled action. The
three kinds have Attach. Ctrl+Enter sends.

Under 700 px the composers are the tabs of one strip, each with its title and
an x; the active one fills the screen, a plus at the strip's end starts another
message, and minimize returns to the mailbox with the strip docked at the bottom.
A sent message or reply shows a toast.

## The studio

`apps/kit/run studio --config <server.toml> [--project <id>]`. Its sections
are a rail down the left edge, in a fixed order:

| Keys | What they do |
| --- | --- |
| 1 … 8 · Ctrl+1 … Ctrl+8 | the section of that number |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous section |

### 16. Flow

The project as a flowchart: you, then a row per depth with its agents and
the workflows a work there may go through, each workspace a zone. The bar
adds an agent, a workflow, a model, a provider or a workspace.

| Keys | What they do |
| --- | --- |
| F | frame it all |
| 0 | its actual size |
| + · - | zoom in and out |
| Tab · Enter | reach an agent's box and pick it |
| Esc | let the agent go |

### 17. Secrets, models, agents, workflows, tools, skills, project

A table of the section's items. A click picks a row; a double click or
Enter opens it. The project section holds the policy, the access (with the
project's members, which it adds and removes), the usage of the model
replies, and the workspaces.

### 18. An item

One item on a screen of its kind, in three columns: its image and facts,
its description, and what is related to it, each related item opening in
its section.

| Keys | What they do |
| --- | --- |
| Ctrl+E | edit |
| Ctrl+S | save the edit |
