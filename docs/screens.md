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

On a project, its name, "What now?" and four ways in as cards, each with
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

The composer, addressed to the project's default agent: "TO", a folded control
with its name, and the box. The start card's line says whom it goes to. Opening
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
it began and its works; then what the newest request asks. Under the
search line, chips filter by state, ALL listing every one; a row's `⋯`
opens it at its tree or its log.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose; ↑ on the first row, the search |
| Enter | open |
| Ctrl+N | new conversation |
| / | search |

### 5. Chat

The chat is the dialogue between you and the root agent, read as a history
from the top down. What you said is a filled bubble on the right; what an
agent says is a bubble on the left tinted with its colour, under its name and
time. A note an agent of the team left is an outlined card headed NOTE FROM
SELLER. Each work handed down is one work card: WORK and its title, its state
as an icon and a word (WORKING, WAITING FOR SURGEON, WAITING FOR YOU, DONE),
how long, who it waits for and OPEN IN TREE, which opens the tree on that work;
the card has no stages and no one at work, which the header strip says once.
What you answered, chose or granted is one sentence with its icon and
word (ANSWERED, CHOSE, GRANTED, DENIED) and the time. There are no run rows,
tool calls or exchanges between agents here: they are in the tree and the
log. While any agent of the team works, a live line at the end of the thread,
at every width, says who, down from the agent you write to, what it does in a
plain verb and for how long. The "N NEW" pill, when the thread runs past the
view, sits above the composer and never over an entry. Over the tabs of every page of the
conversation, a header strip says whom it is with, the stage, or that the
conversation is starting, the step of how many, how long, and how many agents and replies, each
count opening the tree or the cost, with the chevron and ANSWER while
something waits on you; under it the stages of the work in focus, in large type, and the chain
of agents from the one you talk with down to the one at work, with a plain verb
for what it does; the tabs are on one line, without their digits on a narrow window; at their right, "⚠ 3 PENDING" opens
the [pending queue](#6-the-pending-queue). The chevron or Alt+P open the
progress: the works nested by stage and level, beside the thread from 1100 px,
a card over it from 700 px, a sheet over the chat below. The composer is a
line with a clip that attaches files and SEND; it has no options of a request
above it. A conversation with no message yet, opened from the conversations,
shows the TO control of
[a new conversation](#3-a-new-conversation) over the composer when several
agents of depth 0 may take it.

A sub-work's open glyph (an arrow out of a box), or OPEN in the progress, shows that work's thread as a
page of its own, under the way down to it, with a composer to its agent;
OPEN IN TREE (Alt+O) shows it on the tree page.

| Keys | What they do |
| --- | --- |
| Alt+R | open the pending queue |
| Alt+P | open or close the progress, the keyboard in it |
| Alt+M | show the oldest note to you and mark it read |
| Ctrl+N | new conversation |
| Enter, in the composer | send |
| Shift+Enter, in the composer | break the line |
| ↑ · ↓ · → · ←, in the progress | move, unfold, fold |
| Esc, in the progress | back to the composer; the sheet closes |

### 6. The pending queue

Everything whose arbiter you are, reviews included, over any page of the conversation: a panel on
the right, the whole page when narrow, headed "PENDING · 3" with a close
button, the requests oldest first, from the top. It opens only while something
waits and closes when you answer the last one. The keyboard starts in the first
field, or on the recommended action. An item is one of four kinds, each with
its icon and word: QUESTION, DECISION, PERMISSION or REVIEW. It says what it asks in a
sentence, then who asks, the way down from the front desk, the work, what it
unblocks and, for a permission, what it grants or, for a review with several
reviewers, its step; every text wraps inside it. Its
actions are one group at its bottom: a box and ANSWER for a question; a button
per option for a decision, the recommended one (APPROVE or ACCEPT) filled and
the others outlined; GRANT · THIS WORK ONLY, filled, DENY and an ALWAYS… menu of
the wider scopes (for the agent, the stage, the folder or the project, saved
in the project settings) for a permission; APPROVE, filled, EDIT (which opens
the action's text to rewrite and SEND EDIT) and DENY for a review. A note, or the reason of a no, is
behind ADD A NOTE, and the item's "more" menu holds ESCALATE. Acting on an
item removes it and leaves its sentence in the chat.

| Keys | What they do |
| --- | --- |
| Alt+R | open it |
| Enter | in an answer's words: send it, or escalate when escalating |
| Esc | close |

### 7. Tree

The conversation's works in the order they were made, who handed work to
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

What the conversation used: model replies, tokens and cost in all in a
header strip, then a row per agent, its figures in columns or, on a narrow
window, on lines of their own; with no price from the provider, no cost
column, only the kicker NO PRICE REPORTED. It has no keys of its own.

### 10. Board

The works of every project of the registry as a kanban, a column per state
under a rule of each; opened from a project, kept to its works, every
project's one chip away. Under 700 px it is one list, the works under a rule
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

Inbox (with its unread count), Sent, Drafts, Pending (with its review count)
and Archive, named, and the
threads of the folder, newest first, each with its sender, subject, snippet, label and time;
unread ones in bold. Pending lists instead the reviews that wait on you, newest
first, each with the agent that acted and what it wants to do. At phone
width the folders are icons, the current one keeping its name. A command bar
holds COMPOSE and MARK ALL READ.

| Keys | What they do |
| --- | --- |
| Ctrl+N | compose |
| / | search by subject, agent, project, message or file name |
| Esc | clear the search |
| Ctrl+B | fold the folders to a rail |
| Ctrl+L | fold the list to a rail of the agents' portraits |

### 14. A thread

One conversation with an agent of depth 0, stacked oldest first, the latest
message open, with its label in the head. Each open message offers REPLY,
REPLY ALL and FORWARD; a reply is written under the messages.

A review opened from Pending reads as a message in the same pane: its subject
is what the agent wants to do; its body the arguments as lines, the text it
holds and what each answer does. APPROVE is the filled action; EDIT opens the reply box with the held text and sends your words
in its place; DENY opens it for an optional reason.

| Keys | What they do |
| --- | --- |
| Ctrl+R | reply to the latest message |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | close the reply, then the thread |

### 15. Compose

A dialog: To (one agent, as a chip, with autocomplete), Subject, the message,
Attach and SEND, the filled action. It keeps what is written in Drafts when closed.

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
