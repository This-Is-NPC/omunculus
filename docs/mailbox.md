# The mailbox

`apps/mailbox/` is a concept client beside the window, built on the same kit
as it. A thread is a conversation with one agent of depth 0.

`apps/kit/run mailbox` takes the server registry and, when it holds several
projects, the id of the one whose socket it opens through, which it reads as
`OMUNCULUS_SOCKET`.

## How it reads the projects

The `Mail` singleton reads `GET /v1/projects` on the socket it was opened
on, then each project's conversations, each one's snapshot every few seconds
and its events when the snapshot's cursor moved, all through `curl`. Which
messages you read is kept in Quickshell's state directory, and a word from
an agent in a thread not on screen is announced with `notify-send`.

## A new thread

A new thread needs its To, one agent of depth 0 that is not workflow-only,
of one project, as the config tool prints them through `/v1/cli`. Its first
message names that agent, and every later one names it again.

## What a thread shows

The thread shows, newest first as mail reads:

- what you wrote;
- each answer you gave a request whose arbiter is you, as a message of yours
  to whoever asked, its words and the option it chose (the `reply` events
  whose actor is you);
- what each run of an agent of depth 0 said to you — the text of its model
  replies that call no tool, its comments and the files it attached — as
  the kit's `Prose`, its web addresses links that open in the browser;
- each request whose arbiter is you.

An agent's message is headed by its portrait, the kit's `Portrait` of the
picture `AgentImages` fetched for it through its project's socket, or,
while it has none, its initial in its colour, by its place among the
config's agents; yours by none.

A model reply that calls a tool is the agent acting, and its text narrates
the call to itself, as "the question is already out, I'll wait" or a
request's id. It is the agent's note, not words to you, and shows only in
the console, in that run's turn. So an agent whose every reply calls a tool,
as the sales desk's generalist, speaks to you only through its requests and
comments.

## Requests

A request whose arbiter is you, while pending, takes an option or a text
answer through the reply endpoint. Its options are buttons, and so are those
of every decision it gathers from below — an origin still waiting whose
options are named, as an escalation keeps a decision's options on its
origin — each under its part name when there are several, an option of an
origin given through the reply's `parts`, down to it, with the words
written. A request closed without an answer of yours says so.

A request whose `request` event the harness wrote (its `actor.kind` is
`harness`), as when an agent left a question unanswered and the harness
passed it on, asks what it passes on. Its card leads with the questions of
its origins, in their askers' own words and language, under the name of the
first one's asker, and the harness's sentence, which says how it came to
you, follows in small print. The thread's state says who asks and that
question too (the kit's `Requests.byHarness` and `Requests.passedOn`).

One that passes on no question is a note, no one's words: its card reads
NOTE, muted, where the requester's name would be, and the thread's state
says `note:` before its reason rather than who asks.

A request shows each question once: its reason, or, when an origin's
question holds it, that question, then each origin's question the text shown
does not already hold, under its part name, whitespace and case aside.

## Files

A message carries the files you pick with the kit's `FilePicker`, which
`Http.post` sends through `apps/kit/client/post-with-files`, in base64 from a
temporary file. A file a message or an agent's `attach` carries shows as the
kit's `FileChip`, which `Http.openAttachment` saves through
`apps/kit/client/open-attachment` to the downloads directory, beside a
different file of the same name rather than over it, and opens.

## A thread's state

Each thread has a state, read from its snapshot (works with their state and
stage, runs with their status and `via`, requests) and its events. It shows
in its row and, with what happens next, under the open thread's subject:

- WAITING ON YOU while a request whose arbiter is you is pending, with
  DECIDE, and, while nothing else is, when a work you gave waits for your
  next message (a root work whose `waiting` is `message`, as `wait` leaves
  it), naming who waits and on which work, with REPLY;
- WORKING while a run of any depth is open, naming its agent, its work's
  title and stage, and the tools its last model call asked for that have
  not answered yet, and RETRYING (n) when that run is the n-th retry in a
  row on its work, with why the try before failed;
- FAILED when nothing runs and the last run's `end-run` carries an `error`,
  with that reason;
- WAITING ON another participant while nothing runs and a request waits on
  them;
- STALLED when nothing runs, nothing is pending and a work is still open or
  waiting;
- DONE or CANCELLED once every root work is.

Failed and stalled threads offer WRITE AGAIN, which opens the reply. The
panel's actions are outlined in its tone, as the bar's secondary ones, so
the bar's main action stays the one solid on screen. A thread not on screen
that turns so is announced with `notify-send`.

A thread is working while a run is open and waiting for you while such a
request is pending or its work waits for your word. The folders are all
threads, those waiting for you and those working, filtered by project.

## Look and motion

It follows eco's look and motion with the kit's controls:

- the masthead's notch sweeps when the folder changes;
- a row is outlined by a hairline, washed under the pointer and outlined in
  the accent when open, a dot marking it unread, with no edge bar;
- threads arriving fade and rise in, leaving fade out and the rest slide,
  under day kickers;
- subjects decode;
- a thread slides in as a Stage does;
- a thread opens at its newest message, its state and, once asked for, the
  reply above its messages, and a long thread folds its middle above its
  first message, at the bottom;
- a message arriving drops in on top, and those arriving while the top is
  out of view are counted on a NewPill above them, the messages in view
  staying where they are;
- deny and cancel arm on the first press and answer on the second.

Hairlines that fade downwards part the columns. Sending uses eco's enter
icon.

## Search and the command bar

The search box (`/`) finds threads by subject, agent, project, message or
file name a quarter of a second after the last key, Esc clearing it; the
project chips filter the list.

A command bar under the masthead holds the actions, as mail clients do,
ranked in the kit's `CommandRow`: the main action of where you are solid,
the others outlined in order of importance, which slide in when the place
changes, and the search at the end.

On the list NEW THREAD leads, then MARK ALL READ. With a thread open REPLY
leads, then MARK UNREAD and NEW THREAD, except while the thread waits on a
decision of yours: nothing in it moves until you decide, so DECIDE leads, in
the warning tone, before REPLY.

Each action shows its name beside its icon while the names fit; otherwise
every one but the main one shows only its icon, its name in the tip, and on
a narrow window the search moves over the list.

## Moving and the columns

Moving through the threads is not in the bar: the open thread's head holds,
beside its subject, the previous and next thread (Alt+Up, Alt+Down) and
closing it. A new thread is written in a dialog (Ctrl+N); a thread is
answered only after REPLY (Ctrl+R), Esc closing the reply and then the
thread.

How the columns show is not in the bar: each column is headed by its name
and the arrow that folds it. The folders fold to a rail (Ctrl+B), and the
threads (Ctrl+L) to a rail of their agents' portraits, the kit's
`Portrait`, each underlined in the tone of its state, a dot at its corner
while unread, the one open washed and outlined in the accent, its agent,
subject and state in the tip. A click opens one, as Up and Down open the one
before or after with the keyboard on the rail, sliding to their width. A
narrow window shows one pane at a time.
