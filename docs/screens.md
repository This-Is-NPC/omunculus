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
  models that need no network, `fake` and the scripted `Battery`, hand no
  work down and ask nothing, so a project seeded through them would show
  empty pages; fixtures that put a conversation's works and requests in
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
| 1 · 2 · … | the page of that number: the conversations and the board, or, in a conversation, its chat, map, log and cost |
| Ctrl+1 · Ctrl+2 · … | the same, from a field being written or the picker |
| Ctrl+Tab · Ctrl+Shift+Tab | the next or the previous page |
| Esc | let go of what the page holds, then back to where you were, at last the start |
| Alt + a key of the bar | the key, from a field being written |
| ? · F1 | the keys dialog, which lists these tables |

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
| 1 … 9 · Enter | start it with them |

### 3. Conversations

The project's conversations, filtered by what agents do there and what was
first said.

| Keys | What they do |
| --- | --- |
| ↑ · ↓ | choose |
| Enter | open |
| N | new conversation |
| / | search |

### 4. Chat

The chat between you and the root agent: what each of you said and, on a
line below each run, what the agent did. The composer under it counts what
waits on you.

| Keys | What they do |
| --- | --- |
| R | answer the oldest request waiting on you |
| M | show the oldest note to you and mark it read |
| N | new conversation |
| Enter, in the composer | send |

### 5. A request

A request's decision, over the page: who asked, what for and who decides,
its options as buttons, and a field for words, which ANSWER, DENY or
ESCALATE carry.

| Keys | What they do |
| --- | --- |
| Enter | in its words: answer, or escalate when escalating |

### 6. Map

The works of the conversation as a flowchart: you on top, a row per depth,
each work a card with its agent, model, title, state and the tool it calls
while it runs; a work in a workflow a lane of its stages. Requests and
unread notes hang from the work that made them. Picking a work opens its
inspector: the work, and its RUNS, CHANGES and PROMPT.

| Keys | What they do |
| --- | --- |
| F | the whole map in view |
| R | answer what the node picked asked |
| E | escalate what it asked you |
| C | leave it a note, without a run |
| M | mark its notes read |
| W | write to its agent |

### 7. Log

Every event of the conversation, a row each, which opens whole.

| Keys | What they do |
| --- | --- |
| / | filter the events |
| Esc | empty the filter, then back to the rows |

### 8. Cost

What the conversation used: model calls, tokens and cost, in all and by
agent. It has no keys of its own.

### 9. Board

The works of every project of the registry as a kanban, a column per state.

| Keys | What they do |
| --- | --- |
| ← · → · ↑ · ↓ | move between the works, across and down the columns |
| Enter · Space | open the work on its page |
| S · A · P | by state, a lane per agent, a lane per project |
| / | filter the works |
| Esc | empty the filter, then back to the works |

### 10. A work

One work read as an issue: where it is and its title on top; its
description, goal, questions and notes, then its RUNS, CHANGES and PROMPT on
the left; its state, workflow, agent, parent, children and times on the
right.

| Keys | What they do |
| --- | --- |
| R | answer what it asked you |
| O | its conversation's map, the work picked |
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
Enter opens it.

### 17. An item

One item on a screen of its kind, in three columns: its image and facts,
its description, and what is related to it, each related item opening in
its section.

| Keys | What they do |
| --- | --- |
| Ctrl+E | edit |
| Ctrl+S | save the edit |
