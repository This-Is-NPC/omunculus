# What does not work

The defects known today, each with what happens and what to do until it is
fixed. Limits of the platform or of a provider are not here: they are
under [Known limitations](../README.md#known-limitations).

## 1. The console does not show an agent's reply as it arrives

Seen running, on the console's chat page.

**What happens.** Your message shows as soon as it is sent, but the agent's
reply does not: its turn takes no room in the timeline although the reply is
recorded. Opening the conversation again from the conversations page shows
every reply.

**What to do in the meantime.** Press BACK and open the conversation again
from the conversations page, or read the reply in the mailbox.

## 2. A message in an empty conversation opened from the list is refused

Seen running, on the console's chat page.

**What happens.** A conversation that has no message yet names no agent. Opened
from the conversations page, the message you send to it carries none, and the
server refuses it; the console shows `invalid`.

**What to do in the meantime.** Start the conversation with NEW CONVERSATION,
which asks whom it is with.

## 3. Some sandboxed commands fail to set up their overlay

Seen running, in the benchmark with Bubblewrap
([Equivalent Exchange](../eval/README.md)).

**What happens.** Now and then a `bash` call fails before it runs, with
`execution failed: {:bubblewrap, :setup_failed}`, and Bubblewrap prints
`Can't make overlay mount on (null) … Device or resource busy`. In a run of
the whole benchmark at `--jobs 24` it happened in 7 of 133 executions, six
of them in tasks that start servers in the background: the FastAPI tasks
and the agency's design-to-build. Run again at `--jobs 4`, it happened in 7 of those
9 executions; 32 executions of other tasks at `--jobs 12` had none. A run of
2026-10-21 shows it too. Why the mount is busy is not established.

**What to do in the meantime.** The model sees the failure and may call
the command again, which sometimes works. Before reading a failed
measurement of those tasks as the model's, look in its events for
`setup_failed`.
