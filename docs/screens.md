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
| 1 · 2 · … | the page of that number: the projects and the board, a project's conversations and the board, or, in a conversation, its chat, team, log, cost and artifacts; only while you navigate, not a second after typing |
| Ctrl+1 · Ctrl+2 · … | the same, from a field being written or the picker |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous page |
| Ctrl+P | the projects, also from a field being written |
| Esc | let go of what the page holds, then back to where you were, at last the start |
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
`agents`, `log`, `board`, `open <conversation id>`, `work <work id>`,
`newConversation`, `back` and `send <message>`.

### 1. The start

On a project, its name and four ways in: NEW CONVERSATION, CONVERSATIONS,
BOARD and PROJECTS. On the registry alone, how many projects it holds and
two: PROJECTS and BOARD. Under them, in the warning tone, the projects
where conversations need you and how many, each a way into that project's
conversations with NEEDS YOU lit (a line says it is reading until every
project is). The ⓘ at the top right opens the
keys.

| Keys | What they do |
| --- | --- |
| N · H · B · P | a new conversation, the conversations, the board, the projects |

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

"Who do you want to talk with?": a card for each of the project's agents a
conversation can be with, its portrait, its name and its role; under FOR
THE PROJECT ITSELF, a smaller line with the role too for each agent that changes how the
project works, each change only once you approve it. The keyboard is on the
first card, its ring showing it; a card's tooltip gives its number. The
conversation keeps the agent its first message names.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | choose whom it is with |
| 1 … 9 · Enter | choose them; the conversation is made by the first message, not by the choice |

### 4. Conversations

The project's conversations, those needing you first, the longest waiting
first, then the others under a rule of the day each began: its title and
its state at the top right, what waits on you ("7 QUESTIONS", "A
DECISION"); under it since when it waits, whom it is with and which agent
holds its work at which stage ("front-desk · project-manager is at design (2/4)"), when
it began and its works; then what the newest request asks. Under the
search line, chips filter by state, ALL listing every one; a row's `⋯`
opens it at its team or its log.

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
how long, who works for it now and what they do, who it waits for, the stages
of its workflow and OPEN IN TREE, which opens the team page on that work;
narrow, the stages are a bar of one segment each and the button has its own
line. What you answered, chose or granted is one sentence with its icon and
word (ANSWERED, CHOSE, GRANTED, DENIED) and the time. There are no run rows,
tool calls or exchanges between agents here: they are in the tree and the
log. While the agent you write to works, a live line at the end of the thread
says what it does and for how long. Over the tabs of every page of the
conversation, a header strip says whom it is with, the stage, or that the
conversation is starting, how long, and how many agents and replies, each
count opening the team or the cost, with the chevron and ANSWER while
something waits on you; under it one line says the stages of the work in
focus; at the right of the tabs (above them when narrow), "⚠ 3 PENDING" opens
the [pending queue](#6-the-pending-queue). The chevron or Alt+P open the
progress: the works nested by stage and level, beside the thread from 1100 px,
a card over it from 700 px, a sheet over the chat below. The composer is a
line with a clip that attaches files and SEND; it has no options of a request
above it. A conversation with no message yet, opened from the conversations,
first asks whom it is with, on the cards of
[a new conversation](#3-a-new-conversation) when several agents of depth 0
may take it.

A sub-work's open glyph (an arrow out of a box), or OPEN in the progress, shows that work's thread as a
page of its own, under the way down to it, with a composer to its agent;
OPEN IN TEAM (Alt+O) shows it on the team page.

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

Everything that waits on you, over any page of the conversation: a panel on
the right, the whole page when narrow, headed "PENDING · 3" with a close
button, the requests oldest first. An item is one of three kinds, each with
its icon and word: QUESTION, DECISION or PERMISSION. It says what it asks in a
sentence, then who asks, the way down from the front desk, the work, what it
unblocks and, for a permission, what it grants; every text wraps inside it. Its
actions are one group at its bottom: a box and ANSWER for a question; a button
per option for a decision; GRANT · THIS WORK ONLY, DENY and an ALWAYS… menu of
the wider scopes (for the agent, the stage, the folder or the project, saved
in the project settings) for a permission. A note, or the reason of a no, is
behind ADD A NOTE, and the item's "more" menu holds ESCALATE. Acting on an
item removes it and leaves its sentence in the chat.

| Keys | What they do |
| --- | --- |
| Alt+R | open it |
| Enter | in an answer's words: send it, or escalate when escalating |
| Esc | close |

### 7. Team

The conversation's agents as a tree, who handed work to whom, every level
deep. The agent that talks with you is the root, with its own state and
what it asks you; each work sits under the work that handed it down, lines
joining it to its parent as in a file tree. A row is the work's mark (a
chevron while it handed works down, else its agent's dot), its agent in its
tone (a workflow's agents, the one at work lit), its title, and its state at
the right: what it does and a clock, whom it waits on, Needs you. Under them
its stages, time, steps and cost, and a badge for the climb of what it waits
on (⇡ surgeon › administrator › project-manager › front-desk › you) and what it is asked
(⇣). The paths at work or waiting are open; the done works under an open
one fold into one line ("✓ 3 sub-works done · 30 min · toolsmith, surgeon
×2"), those up next into another, each unfolding on a click. Chips keep the
works that need you or work, with the works above them. The work picked
shows in full under a header strip with ANSWER or OPEN THREAD, in the tabs
OVERVIEW, THREAD, REQUESTS, CHANGES, RUNS and LOG: beside the tree from
1100 px, as a page over it narrower.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | move from row to row; the detail follows |
| → · ← | unfold, or the first row under it; fold, or its parent |
| Enter | open its detail, or its tabs beside the tree; a fold, unfold or fold it |
| [ · ] | the previous or next tab |
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

Each row is one line: when, its kind, what the event says, who. Chips keep
the events that need you or failed, a picker one agent's, and BEHIND THE
SCENES brings back the plumbing (run starts and ends, hooks), dimmed; a rule
names each day and each run. The count says how many rows a filter keeps out,
and "2 BEHIND THE SCENES HIDDEN" when that is why. A failed event has the
warning icon in the error tone. Opened from a work of
the team, it is kept to that work.

### 9. Cost

What the conversation used: model replies, tokens and cost in all in a
header strip, then a row per agent; with no price from the provider, no cost
column, only a note. It has no keys of its own.

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
| Alt+O | its conversation's team, the work picked |
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

Inbox (with its unread count), Sent, Drafts and Archive, named, and the
threads of the folder, newest first, each with its sender, subject, snippet, label and time;
unread ones in bold. A command bar holds COMPOSE and MARK ALL READ.

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
