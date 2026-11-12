# The mailbox

`apps/mailbox/` is the requester's view of a project, drawn as an ordinary
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
- what the thread's agent addressed to you: its comments on the
  conversation's root work and the files it attached, one e-mail per run. A
  file shows on the e-mail of its own run: the request that run raised, else
  its comments, else an e-mail of its own with no text;
- each question (a request that is not a review) whose arbiter is you, in
  the thread of its conversation, as an e-mail from its own requester (its
  name, its address and portrait: the thread's agent or any other agent) whose
  body is the request's reason, in the requester's own words. The questions of
  the request's origins are other agents' text and never appear;
- your answers to those requests, as e-mails of yours to their requester;
- your answers to reviews, as e-mails of yours to the account that acted:
  "Approved: <what it wanted to do>", with the words of an edit or a denial.
  They put the thread in Sent.

What reaches you is what is addressed to you: a request is mail only when you
are its arbiter. An account is an account, agent or human: a question an agent asks you
reaches you whoever it is, and a request for another account is never shown.
A thread whose only pending requests are another account's reads in progress. A review
of a held action ([interception](requests.md#interception)) is not mail: the
Pending folder holds it, and no thread shows it.

The channel to the person is explicit. An agent speaks to you only through a
request to you (`ask`, or `escalate` to the origin), a `comment` on the
conversation's root work and `attach`. What a model writes in plain text, beside
a call or with none, is the agent's own narration: the console shows it, the
mailbox never does. A comment on any other work, and the note of an `attach`,
are not shown either. Nothing else of another agent is shown: not its words, not
requests for other accounts, not a note the harness opened between agents (a
request the harness opened that passes on no question). A request the harness
opened that passes on a question shows that question, from the request's
requester.

A conversation has no title in the core: its subject is the first line of its
first message of yours, cut at 90 characters. A composer's Subject is
sent as that first line, followed by a blank line and the message.

An agent's address is `<agent>@<project>` and its display name the agent's name,
capitalised: `Front-desk <front-desk@agency>`.

## Folders

- **Inbox**: threads with at least one e-mail from the agent. A dot and bold
  type mark a thread with unread mail; the count is how many.
- **Sent**: threads with a message of yours.
- **Drafts**: what you left unsent.
- **Pending**: the reviews of held actions that wait on you, whoever acted,
  newest first, with their count on the folder. Opening one reads it as a
  message ([Reviews](#reviews)). It holds reviews, not threads, and a review
  leaves it once decided.
- **Archive**: threads you archived. A thread that gets new mail after it was
  archived returns to the inbox.

The folders show their names, with the unread count on Inbox and the review count on Pending. Ctrl+B folds them
to icons, and a window narrower than 760 px shows icons only, in one row that
shows every folder without scrolling, the current one keeping its name.

Only you opening a thread (a click, Enter, or Alt+Up and Alt+Down) marks it read; mail that arrives in the thread on screen stays unread until you open it again. MARK UNREAD marks it unread and goes back to the
list. A row shows who wrote ("Front-desk, me (5)") and the time, then the subject
and the start of the last message, with the label beside them. In a list
narrower than 380 px the snippet is left out and the label takes a line of its
own, so the sender and the subject keep the width. Which project an agent is
in shows only in its address (`front-desk@agency`); search can still match it.

## Labels

A thread has at most one label, on its row and in its header, a small pill
with a still icon and a word:

- **In progress**: a run of the conversation is open, a request waits on
  someone other than you (a request whose arbiter is another account), or a
  work waits on its children. A thread whose only pending requests are
  another account's reads so.
- **Stuck**: nothing runs, nothing waits for you, and the last run failed or a
  work is still open.
- **Cancelled**: every root work is cancelled.

There is no label otherwise, including while the agency waits for you: that is
an unread e-mail.

## Reading and replying

Opening a thread stacks its messages, the latest open and the others folded to
a line. Click a message to open or fold it. An open message offers REPLY,
FORWARD, and REPLY ALL only when the thread has several counterparts (the agent
and others who wrote in it, such as a requester); with one, there is only REPLY.
The latest message's REPLY is the screen's one filled action. The command bar
offers ARCHIVE (MOVE TO INBOX in the archive), MARK UNREAD and COMPOSE.

A reply is written in a composer ([Composing](#composing)) docked over the
mailbox at the bottom right, so the thread stays readable beside it. Its To is
chips (the same field as a new message, with its type-ahead and address book),
prefilled with the sender, or with every counterpart for REPLY ALL, and its
Subject is the thread's, "Re: ...". Taking a chip off or adding another is
free; the thread's own accounts are answered in it, and any other recipient gets
a message of its own with the same subject. Behind MORE the composer shows the
e-mail it answers, quoted as mail does ("On <date>, Front-desk wrote:" and its
lines behind "> "). Only your own words are sent, never the quote. Asking for
the reply to a message that already has a composer shows that one again. What it
does:

- replying to an open request's e-mail sends your words as the answer to that
  request (`POST .../requests/{id}/reply` with `{"body": text}`);
- replying to any other e-mail while requests wait for you answers the newest
  of them, and the quote shows which one;
- with no request waiting, it is a message to the agent
  (`POST .../messages`), and may carry files.

An answer to a question carries words only, never an option, and no files.

FORWARD opens a composer with `Fwd:` and the message below your words.

## Reviews

A review opens in the right pane as a message from the agent that acted. Its
subject is the sentence of what it wants to do ("Seller wants to run promote").
Its body is the action's arguments, one `name: value` line each, with the web
addresses they hold as links; the text the action holds; and a last line that
says what each answer does ("If you approve: Seller goes ahead as written. Edit
changes its text. Deny tells Seller no."). The step of a review among several
reviewers shows in the console, not here. It offers three actions:

- APPROVE, the one filled action, lets the action go ahead as it is
  (`POST .../requests/{id}/reply` with `{"option": "approve", "body": "approve"}`);
- EDIT opens the reply box filled with the held text. SEND replies with option
  `edit` and your words, which go ahead in place of the held text
  (`{"option": "edit", "body": text}`); it needs some text;
- DENY opens the reply box for a reason, which may stay empty. SEND replies
  with option `deny` (`{"option": "deny", "body": reason}`, the body being
  `deny` when empty).

Once you answer, the three buttons turn off and SENDING shows. When the
server has taken the answer, the review leaves Pending and a line confirms
it ("Approved: ..." or "Edited: ...", "Denied: ..."); if it did not, a line
says so and the buttons come back.

A review that is not yours to decide is not listed. The console's chat
holds the same reviews, as cards.

## Composing

COMPOSE (Ctrl+N), REPLY and FORWARD each open one composer, the same window
for all three. It is not part of the mailbox's layout: it floats over the
content at the bottom right, as a mail client's compose window does, and the
thread or list under it keeps its place and its width.

- **Several side by side.** Each composer has its own words. The newest sits at
  the right edge, the older ones shift left; when there is no room for another
  window (each is 360 px wide), the older ones collapse to tabs, narrower as
  they grow in number.
- **The bar.** The title is the subject (or "New message"). MINIMIZE (or Esc)
  folds the composer to a tab of its bar, docked at the bottom, which keeps
  what is written; a click on the tab restores it. EXPAND shows the composer
  large and centred over a dim backdrop, one at a time; a press on the backdrop
  or EXPAND again docks it. CLOSE closes it; with something written (a body, a
  new message's subject, a file; the prefilled subject, quote and forward text
  do not count) it first asks: SAVE DRAFT keeps it in Drafts, DISCARD drops it,
  KEEP WRITING goes back. Without words it closes at once.
- **The content.** To, Subject, the body, which fills the window's height and
  scrolls past it, the files, and the footer with the attach button, DISCARD
  (which closes as above) and SEND, the filled action, enabled once there is a
  recipient and some text. Ctrl+Enter sends. A sent message gets no toast: it
  appears in the thread.
- **A phone** (under 700 px). The composers are the tabs of one strip, each
  with its title and an x. The active one fills the screen under the strip;
  the button at the strip's end minimizes it, back to the mailbox with the
  strip docked at its bottom. A tab opens its composer.

- To holds one agent as a pill with its display name, its address in the tip
  and an x on the right (`RecipientField`). A click on the pill selects it; only
  its x, or Backspace once it is selected (or in the empty field), removes it.
  The field beside it lists nothing until you type; then, in a floating list
  under it that never moves the form, the agents whose name or address holds
  what you typed, case aside; Up and Down move, Enter or a click picks, Esc or a
  click outside closes the list. The address-book button at the right end of the
  field floats every agent you can write to, with a search box, and picks one.
  The agents are those of depth 0 that are not workflow-only,
  as the config route gives them, of the projects where the capabilities route
  grants `conversation.create` and `conversation.send`. They are ordered: the
  project the window was opened on, its default agent first, then the rest of
  that project, then the other projects. A second recipient is refused with a
  sentence saying a message goes to one agent.
- To starts empty; no agent is chosen for you. When the project's config
  declares a `default_agent`, the empty field says "to Front desk if left
  empty" and a message with no recipient names no agent: the server sends it to
  the default agent. With none declared, the field says "name or address" and
  SEND waits for a recipient.
- A draft opens in a composer again, and is gone once sent. The state of the
  composers lives in `apps/kit/client/Composers.js`, tested in
  `test/omunculus/gui_composers_test.exs`.
- Files are attached with the attach button (the kit's `FilePicker`) and sent
  through `Http.post` and `apps/kit/client/post-with-files`. A file waiting to be sent is a neutral chip as tall as the attach button (a file icon, its name and a small x). A file an e-mail
  carries shows as the kit's `FileChip`, which `Http.openAttachment` saves to
  the downloads directory and opens.

## Look and motion

It follows the console's look with the kit's controls: hairline rows, no
coloured edge bars, status as an icon and a word, one solid action per screen.
The masthead's notch sweeps when the folder changes; arriving threads fade and
rise in; a thread fades in. Subjects never animate.

## Search and keys

The search box (`/`) finds threads by subject, agent, project, message or file
name; Esc clears it.

| Keys | What they do |
| --- | --- |
| Ctrl+N | compose |
| Ctrl+R | reply to the latest message |
| / | search |
| Ctrl+B · Ctrl+L | fold the folders, or the list to a rail with its count |
| Alt+Up · Alt+Down | the thread before or after |
| Esc | minimize the composer in focus; else close the thread |
| Ctrl+Enter | send, in a composer |

A narrow window shows one pane at a time; the thread's head has a way back to
the list. Under 700 px every button and icon button is 44 px tall (`Theme.size.control`),
and a link shows no address box, which only a pointer reads; wider, the box sits
under the pointer's line, inside the window. Only the latest message from the
agent has the filled REPLY. A thread's participants name everyone who wrote
in it.

IPC (`quickshell ipc --path apps/mailbox call mailbox <function>`): `compose`,
`open <key>`, `search <query>`, `fold folders|list` and `reply`.
