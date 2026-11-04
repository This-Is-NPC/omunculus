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
project id of it.

These keys work on every screen of the console:

| Keys | What they do |
| --- | --- |
| Tab · Shift+Tab | move between controls |
| Enter · Space | press the control |
| 1 · 2 · … | the page of that number: the conversations and the board, or, in a conversation, its chat, team, log and cost; only while you navigate, not a second after typing |
| Ctrl+1 · Ctrl+2 · … | the same, from a field being written or the picker |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous page |
| Esc | let go of what the page holds, then back to where you were, at last the start |
| Alt + a key of the page | the key, from a field being written |
| ? · F1 | the keys dialog, which lists these tables |

Under 700 px there is no rail of pages: the bar's page switcher names the
page and lists the others, and the commands that do not fit are in its `⋯`
menu. The window is at least 360 by 480 px.

Typed text never runs a command: nothing that sends, answers, grants, denies,
escalates, reverts, deletes or cancels has a key of its own outside a field,
and a key pressed with no field to take it only says "Click a field to type".

The console answers Quickshell IPC too (`quickshell ipc --path apps/console
call omunculus <function>`): `start`, `page <name>`, `conversations`,
`agents`, `log`, `board`, `open <conversation id>`, `work <work id>`,
`newConversation`, `back` and `send <message>`.

### 1. The start

The project's name and three ways in: NEW CONVERSATION, CONVERSATIONS and
BOARD.

| Keys | What they do |
| --- | --- |
| N · H · B | a new conversation, the conversations, the board |

### 2. A new conversation

A card for each agent of depth 0 a conversation can be with, its portrait
on it. The conversation keeps the agent its first message names.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | choose whom it is with |
| 1 … 9 · Enter | choose them; the conversation is made by the first message, not by the choice |

### 3. Conversations

The project's conversations, filtered by what agents do there and what was
first said.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose |
| Enter | open |
| Ctrl+N | new conversation |
| / | search |

### 4. Chat

The chat between you and the root agent: what each of you said and, under
each run, its tool calls, folded to one line that counts them and unfolding
to one row per call. A work handed down is a SUB-WORK block where it was,
which unfolds into its own transcript, changes and runs. A question for you
is a card in the thread; what an agent asked another is an exchange in the
thread it was asked in, which DECIDE INSTEAD lets you answer. Over the
thread, two lines say the stages of the work in focus and who works on it,
doing what, for how long, with ANSWER while a question waits on you; its
chevron, PROGRESS or Alt+P open the progress: the works nested by stage and
level, beside the thread from 1100 px, a card over it from 700 px, a sheet
over the chat below. A conversation with no message yet, opened from the
conversations, first asks whom it is with, on the cards of
[a new conversation](#2-a-new-conversation) when several agents of depth 0
may take it.

A sub-work's OPEN, or OPEN in the progress, shows that work's thread as a
page of its own, under the way down to it, with a composer to its agent;
OPEN IN TEAM (Alt+O) shows it on the team page.

| Keys | What they do |
| --- | --- |
| Alt+R | put the keyboard in the words of the newest question waiting on you |
| Alt+P | open or close the progress, the keyboard in it |
| Alt+M | show the oldest note to you and mark it read |
| Ctrl+N | new conversation |
| Enter, in the composer | send |
| Shift+Enter, in the composer | break the line |
| ↑ · ↓ · → · ←, in the progress | move, unfold, fold |
| Esc, in a question's card or the progress | back to the composer; the sheet closes |

### 5. A request

A request's decision, over the page: who asked, what for and who decides,
its options as buttons, and a field for words, which ANSWER, DENY or
ESCALATE carry.

| Keys | What they do |
| --- | --- |
| Enter | in its words: answer, or escalate when escalating |

### 6. Team

Every work of the conversation, one row each, nested under the stage of the
work that handed it down, siblings handed down together headed "N in
parallel": its agent and state, title, stages, what it does, what it waits on
(⇡) and what it is asked (⇣), and its branch's time, calls and cost. Chips
keep the works that need you or work. The work picked shows in full, in the
tabs OVERVIEW, THREAD, REQUESTS, CHANGES, RUNS and LOG: beside the outline
from 1100 px, as a page over it from 700 px; under 700 px each level is a
page under a breadcrumb, a row going one level down. From 900 px MAP shows
the works as a chart, one card per work, the work picked beside it.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | move between the works; the detail follows |
| → · ← | unfold, fold; on a folded work, go to its parent |
| Enter | open its detail, or its tabs beside the outline |
| [ · ] | the previous or next tab |
| / | filter the works |
| Alt+R | answer what waits on you nearest the work picked |
| Alt+E | open the decision of what it asked you, to escalate |
| Alt+W | write to its agent |
| Alt+C | leave it a note, without a run |
| Alt+M | mark its notes read |
| Alt+L · Alt+G | its LOG and CHANGES tabs |
| Alt+F | the whole map in view |
| Esc | the detail, then the outline, then back |

### 7. Log

Every event of the conversation, a row each, which opens whole.

| Keys | What they do |
| --- | --- |
| / | filter the events |
| Esc | empty the filter, then back to the rows |

Chips keep the events that ask you, the failed ones, one agent's or one
depth's; a title row begins each run. Opened from a work of the team, it is
kept to that work.

### 8. Cost

What the conversation used: model calls, tokens and cost, in all and by
agent. It has no keys of its own.

### 9. Board

The works of every project of the registry as a kanban, a column per state.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | move between the works, across and down the columns |
| Enter · Space | open the work on its page |
| Alt+S · Alt+A · Alt+J | by state, a lane per agent, a lane per project |
| / | filter the works |
| Esc | empty the filter, then back to the works |

### 10. A work

One work read as an issue: where it is and its title on top; its
description, goal, questions and notes, then its RUNS, CHANGES and PROMPT on
the left; its state, workflow, agent, parent, children and times on the
right.

| Keys | What they do |
| --- | --- |
| Alt+R | answer what it asked you |
| Alt+O | its conversation's team, the work picked |
| Esc | back |

### 11. The keys dialog

`?` or F1 opens it on any screen: every key above, by where it works. The
arrows and PgUp/PgDn scroll it.

## The mailbox

`apps/kit/run mailbox --config <server.toml> [--project <id>]`. Its IPC
(`quickshell ipc --path apps/mailbox call mailbox <function>`):
`newThread`, `open <key>`, `search <query>`, `fold folders|threads` and
`reply`.

### 12. The threads

The folders — all threads, those waiting for you and those working — the
project chips, and the threads of the folder, newest first, each with its
state. A command bar holds NEW THREAD and MARK ALL READ.

| Keys | What they do |
| --- | --- |
| Ctrl+N | a new thread |
| / | search threads by subject, agent, project, message or file name |
| Esc | clear the search |
| Ctrl+B | fold the folders to a rail |
| Ctrl+L | fold the threads to a rail of their agents' portraits |

### 13. A thread

One conversation with an agent of depth 0, newest first: what you wrote,
what the agent said to you, and each request whose decision is yours, with
its options. Its state and what happens next head it.

| Keys | What they do |
| --- | --- |
| Ctrl+R | reply |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | close the reply, then the thread |

### 14. A new thread

A dialog: its To, an agent of depth 0 of one project, and the first
message, with the files it carries.

## The studio

`apps/kit/run studio --config <server.toml> [--project <id>]`. Its sections
are a carousel down the left edge:

| Keys | What they do |
| --- | --- |
| 1 … 8 · Ctrl+1 … Ctrl+8 | the section of that number |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous section |

### 15. Flow

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

### 16. Secrets, models, agents, workflows, tools, skills, project

A table of the section's items. A click picks a row; a double click or
Enter opens it. The project section holds the policy, the access (with the
project's members, which it adds and removes), the usage of the model
replies, and the workspaces.

### 17. An item

One item on a screen of its kind, in three columns: its image and facts,
its description, and what is related to it, each related item opening in
its section.

| Keys | What they do |
| --- | --- |
| Ctrl+E | edit |
| Ctrl+S | save the edit |
