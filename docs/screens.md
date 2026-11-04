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
| 1 · 2 · … | the page of that number: the projects and the board, a project's conversations and the board, or, in a conversation, its chat, team, log and cost; only while you navigate, not a second after typing |
| Ctrl+1 · Ctrl+2 · … | the same, from a field being written or the picker |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous page |
| Ctrl+P | the projects, also from a field being written |
| Esc | let go of what the page holds, then back to where you were, at last the start |
| Alt + a key of the page | the key, from a field being written |
| ? · F1 | the keys dialog, which lists these tables |

Under 700 px there is no rail of pages: the bar's page switcher names the
page and lists the others, and the commands that do not fit are in its `⋯`
menu. In a conversation there is neither rail nor bar: tabs under its head
choose its pages, and the masthead's `$`, `⋯` and × open its cost, its rarer
actions and the conversations. The window is at least 360 by 480 px.

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
two: PROJECTS and BOARD.

| Keys | What they do |
| --- | --- |
| N · H · B · P | a new conversation, the conversations, the board, the projects |

### 2. Projects

Every project of the server's registry, under a rule of its state (NEEDS
YOU, WORKING, IDLE): its id, OPEN beside the one the window is on, its
conversations and open works, its last activity, and its state at the top
right — WAITING FOR YOU, WORKING, IDLE, NOT REACHABLE or READING… — waiting
for you first. Under the search line, chips keep those waiting for you or
working. NEW PROJECT
registers another with the server: its id and the path of its config file.
The masthead names the way to every page from here on; the project's name
in it opens this page, and `▲ 2 ELSEWHERE` on its right, while requests wait
for you in other projects, opens it with those waiting picked out.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose |
| Enter | open it, at its conversations |
| / | search the ids |
| Esc | back |

### 3. A new conversation

A card for each agent of depth 0 a conversation can be with: its portrait,
its name in its colour and its role, its number at the top left. The conversation keeps the agent its first message names.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | choose whom it is with |
| 1 … 9 · Enter | choose them; the conversation is made by the first message, not by the choice |

### 4. Conversations

The project's conversations under a rule of the day each began: its title,
under it the agent, when it began, its works and stage, and its state at the
top right. Under the search line, chips filter by what agents do there; a
row's `⋯` opens it at its team or its log.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose; ↑ on the first row, the search |
| Enter | open |
| Ctrl+N | new conversation |
| / | search |

### 5. Chat

The chat between you and the root agent: what each of you said and, under
each run, its tool calls, folded to one line that counts them and unfolding
to one row per call. A work handed down is a SUB-WORK block where it was,
which unfolds into its own transcript, changes and runs. A question for you
is a card in the thread; a numbered list of questions keeps SEND and I CAN'T
ANSWER THIS on the view's bottom edge, with how many questions are below,
until the card's end comes into view. What an agent asked another is an exchange in the
thread it was asked in, which DECIDE INSTEAD lets you answer. Over the tabs
of every page of the conversation, a header strip says whom it is with, the
stage, or that the conversation is starting, how long, and how many agents
and calls, each count opening the team or the cost, with the chevron and
ANSWER while a question waits on you; under it two lines say the stages of
the work in focus and who works on it, doing what, for how long, or what you
are asked ("sales asks you 7 questions"). While agents work after your
message, a working row in the thread says who works and on what. The
chevron or Alt+P open the progress: the works nested by stage and level, beside the
thread from 1100 px, a card over it from 700 px, a sheet over the chat below.
While a decision waits on you, its options are numbered chips over the
composer, then PROGRESS; one pressed decides it. The clip in the composer
attaches files. A conversation with no message yet, opened from the
conversations, first asks whom it is with, on the cards of
[a new conversation](#3-a-new-conversation) when several agents of depth 0
may take it.

A sub-work's open tool (›), or OPEN in the progress, shows that work's thread as a
page of its own, under the way down to it, with a composer to its agent;
OPEN IN TEAM (Alt+O) shows it on the team page.

| Keys | What they do |
| --- | --- |
| Alt+R | put the keyboard in the words of the newest question waiting on you |
| Alt+P | open or close the progress, the keyboard in it |
| Alt+1 … Alt+9 | the quick chip of that number: an option of the newest decision, which decides it, then the progress |
| Alt+M | show the oldest note to you and mark it read |
| Ctrl+N | new conversation |
| Enter, in the composer | send |
| Shift+Enter, in the composer | break the line |
| ↑ · ↓ · → · ←, in the progress | move, unfold, fold |
| Esc, in a question's card or the progress | back to the composer; the sheet closes |

### 6. A request

A request's decision, over the page, as its card: who asked, what for and
who decides, a field for words, and its options as buttons at the bottom
left, with SEND while words are written and DENY last. The card's "more"
menu holds ESCALATE, which makes the words the reason it goes up.

| Keys | What they do |
| --- | --- |
| Enter | in its words: answer, or escalate when escalating |

### 7. Team

The works of the conversation a level at a time, under a breadcrumb: a
work's own row, then the works it handed down under a rule for the stage
that handed them down ("STAGE DESIGN · 2 IN PARALLEL"), those done folded
into one rule. A row is the work's title and state, its agent, stages and
branch's time, calls and cost, and a badge for what it waits on (⇡) and
what it is asked (⇣); its tool goes down a level. Chips keep the works that
need you or work. The work picked shows in full under a header strip with
ANSWER or OPEN THREAD, in the tabs OVERVIEW, THREAD, REQUESTS, CHANGES, RUNS
and LOG: beside the outline from 1100 px, as a page over it narrower. From
900 px OUTLINE and MAP, beside the search line, show the works as a chart,
one card per work, the work picked beside it.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | move between the works; the detail follows |
| → · ← | down a level or unfold; fold or up a level |
| Enter | open its detail, or its tabs beside the outline |
| [ · ] | the previous or next tab |
| / | filter the works |
| Alt+R | answer what waits on you nearest the work picked |
| Alt+E | open the decision of what it asked you, to escalate (the detail's `⋯` ESCALATE) |
| Alt+W | write to its agent (`⋯` WRITE TO ITS AGENT) |
| Alt+C | leave it a note, without a run (`⋯` LEAVE A NOTE) |
| Alt+M | mark its notes read (the detail's `⋯` MARK READ) |
| Alt+L · Alt+G | its LOG and CHANGES tabs |
| Alt+F | the whole map in view |
| Esc | the detail, then the outline, then back |

### 8. Log

Every event of the conversation, a row each, which opens whole.

| Keys | What they do |
| --- | --- |
| / | filter the events |
| Esc | empty the filter, then back to the rows |

Each row is what the event says over when, what kind, who and on which
work. Chips keep the events that ask you or failed, and pickers one agent's
or one level's; a rule names each day and each run. Opened from a work of
the team, it is kept to that work.

### 9. Cost

What the conversation used: model calls, tokens and cost in all in a
header strip, then a row per agent. It has no keys of its own.

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
`newThread`, `open <key>`, `search <query>`, `fold folders|threads` and
`reply`.

### 13. The threads

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

### 14. A thread

One conversation with an agent of depth 0, newest first: what you wrote,
what the agent said to you, and each request whose decision is yours, with
its options. Its state and what happens next head it.

| Keys | What they do |
| --- | --- |
| Ctrl+R | reply |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | close the reply, then the thread |

### 15. A new thread

A dialog: its To, an agent of depth 0 of one project, and the first
message, with the files it carries.

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
