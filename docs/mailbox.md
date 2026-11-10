# The mailbox

`apps/mailbox/` is the client's view of a project, drawn as an ordinary
e-mail client, built on the same kit as the console. A thread is one
conversation of one project, with the agent of depth 0 you first wrote to. It
has no forms, answer buttons or state banners: the agency writes e-mails, you
read and reply.

`apps/kit/run mailbox` takes the server registry and, when it holds several
projects, the id of the one whose socket it opens through, which it reads as
`OMUNCULUS_SOCKET` (`OMUNCULUS_PROJECT` names it).

## How it reads the projects

The `Mail` singleton reads `GET /v1/projects` on the socket it was opened on,
then each project's conversations, each one's snapshot every few seconds and
its events when the snapshot's cursor moved, all through `curl`. The mapping
from a conversation to e-mails is the plain module
`apps/kit/client/Mailbox.js`, tested in `test/omunculus/gui_mailbox_test.exs`.

A mail from an agent in a thread not on screen is announced with
`notify-send`.

What the mailbox keeps itself, in Quickshell's state directory: which threads
you read (`seen.json`), which you archived (`archive.json`) and your drafts
(`drafts.json`). None of it reaches the server.

## What a thread shows

The e-mails of a thread, oldest first, are:

- what you wrote, from you, to the agent;
- what the thread's agent said to you: the text of its model replies that call
  no tool, its comments and the files it attached, one e-mail per run;
- each request whose requester is the thread's agent and whose arbiter is you,
  as an e-mail from that agent whose body is the request's reason, in the
  agent's own words. The questions of the request's origins are other agents'
  text and never appear;
- your answers to those requests, as e-mails of yours.

A model reply that calls a tool is the agent acting, and its text narrates the
call to itself; it is not shown. Nothing of another agent is shown: not its
words, not requests it raised, not a note the harness opened between agents
(a request the harness opened that passes on no question). A request the
harness opened that passes on a question shows that question as the thread's
agent's.

A conversation has no title in the core: its subject is the first line of its
first message of yours, cut at 90 characters. The compose window's Subject is
sent as that first line, followed by a blank line and the message.

An agent's address is `<agent>@<project>` and its display name the agent's name,
capitalised: `Sales <sales@agency>`.

## Folders

- **Inbox**: threads with at least one e-mail from the agent. A dot and bold
  type mark a thread with unread mail; the count is how many.
- **Sent**: threads with a message of yours.
- **Drafts**: what you left unsent.
- **Archive**: threads you archived. A thread that gets new mail after it was
  archived returns to the inbox.

Only you opening a thread (a click, Enter, or Alt+Up and Alt+Down) marks it read; mail that arrives in the thread on screen stays unread until you open it again. MARK UNREAD marks it unread and goes back to the
list. A row shows who wrote ("Sales, me (5)"), the subject, the start of the
last message, its label, the project and the time.

## Labels

A thread has at most one label, on its row and in its header:

- **In progress**: a run of the conversation is open, a request waits on
  someone other than you, or a work waits on its children.
- **Stuck**: nothing runs, nothing waits for you, and the last run failed or a
  work is still open.
- **Cancelled**: every root work is cancelled.

There is no label otherwise, including while the agency waits for you: that is
an unread e-mail.

## Reading and replying

Opening a thread stacks its messages, the latest open and the others folded to
a line. Click a message to open or fold it. An open message offers REPLY,
REPLY ALL and FORWARD. The latest message's REPLY is the screen's solid action;
REPLY ALL does the same as REPLY, since a thread has one agent. The command bar
offers ARCHIVE (MOVE TO INBOX in the archive), MARK UNREAD and COMPOSE.

A reply is written in a box under the messages, outside their scrolling, so
SEND stays in view while you type. Under your text it shows the e-mail it
answers, quoted as mail does ("On <date>, Sales wrote:" and its lines behind
"> ", folded after four lines, MORE shows the rest). Only your own words are
sent, never the quote. What it does:

- replying to an open request's e-mail sends your words as the answer to that
  request (`POST .../requests/{id}/reply` with `{"body": text}`);
- replying to any other e-mail while requests wait for you answers the newest
  of them, and the quote shows which one;
- with no request waiting, it is a message to the agent
  (`POST .../messages`), and may carry files.

An answer carries words only, never an option, and no files.

FORWARD opens the compose window with `Fwd:` and the message quoted.

## Composing

COMPOSE (Ctrl+N) opens a dialog: To, Subject, the message, Attach, SEND.

- To holds one agent as a chip. A click on the chip selects it; only its x, or
  Backspace once it is selected, removes it. The field beside it lists, under
  it, the agents whose name or address holds what you type, case aside (all of
  them while it is empty); Up and Down move, Enter or a click picks, Esc
  closes the list. The agents are those of depth 0 that are not workflow-only,
  as the config route gives them, of the projects where the capabilities route
  grants `conversation.create` and `conversation.send`. They are ordered: the
  current project's default agent, the rest of that project, then the other
  projects. A second recipient is refused with a sentence saying a message
  goes to one agent.
- When the project's config declares a `default_agent` (the config route's
  `default_agent`), To starts with it: the project being filtered on, else the
  one the window was opened on. With none declared, To starts empty.
- Closing the dialog with something written keeps it in Drafts; DISCARD drops
  it. A draft opens in the dialog again, and is gone once sent.
- Files are attached with the attach button (the kit's `FilePicker`) and sent
  through `Http.post` and `apps/kit/client/post-with-files`. A file an e-mail
  carries shows as the kit's `FileChip`, which `Http.openAttachment` saves to
  the downloads directory and opens.

## Look and motion

It follows the console's look with the kit's controls: hairline rows, no
coloured edge bars, status as an icon and a word, one solid action per screen.
The masthead's notch sweeps when the folder changes; arriving threads fade and
rise in; a thread fades in. Subjects never animate.

## Search and keys

The search box (`/`) finds threads by subject, agent, project, message or file
name; Esc clears it. The project chips filter the list when there are several
projects.

| Keys | What they do |
| --- | --- |
| Ctrl+N | compose |
| Ctrl+R | reply to the latest message |
| / | search |
| Ctrl+B · Ctrl+L | fold the folders, or the list to a rail of portraits |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | close the reply, then the thread |

A narrow window shows one pane at a time; the thread's head has a way back to
the list.

IPC (`quickshell ipc --path apps/mailbox call mailbox <function>`): `compose`,
`open <key>`, `search <query>`, `fold folders|list` and `reply`.
