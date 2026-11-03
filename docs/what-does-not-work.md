# What does not work

The defects known today, each with what happens and what to do until it is
fixed. Limits of the platform or of a provider are not here: they are
under [Known limitations](../README.md#known-limitations).

## 1. The codex-like preset's `cursor` model has no program

Read in the code.

**What happens.** `priv/presets/codex-like/omunculus.toml` declares the
model `cursor` with `command = ["./bridges/cursor-agent"]`, a program the
preset does not ship. A project from that preset loads, and its agents run
on `fake`; an agent put on `cursor` fails each run, since the program is
not there.

**What to do in the meantime.** Leave the agents off `cursor`, or point its
`command` at a program of your own that speaks the sandbox NDJSON protocol
([the TOML](config.md#the-adapters)).

## 2. The console does not show an agent's reply as it arrives

Seen running, on the console's chat page.

**What happens.** Your message shows as soon as it is sent, but the agent's
reply does not: its turn takes no room in the timeline although the reply is
recorded. Opening the conversation again from the conversations page shows
every reply.

**What to do in the meantime.** Press BACK and open the conversation again
from the conversations page, or read the reply in the mailbox.

## 3. A message in an empty conversation opened from the list is refused

Seen running, on the console's chat page.

**What happens.** A conversation that has no message yet names no agent. Opened
from the conversations page, the message you send to it carries none, and the
server refuses it; the console shows `invalid`.

**What to do in the meantime.** Start the conversation with NEW CONVERSATION,
which asks whom it is with.
