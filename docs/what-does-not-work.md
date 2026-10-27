# What does not work

The defects known today, each with what happens and what to do until it is
fixed. Limits of the platform or of a provider are not here: they are
under [Known limitations](../README.md#known-limitations).

## 1. Some refusals print as Elixir terms

Seen running.

**What happens.** A refusal the command line has no sentence for prints as
the Elixir term of its reason, on stderr, with exit status 1. Among them:
`send` without `--agent` where several agents have depth 0, as in a project
from the default preset,
`{:prompt, {:agent_required, 0, ["auditor", "concierge", "refiner", "steward"]}}`;
`access bootstrap` on a project without `[access]`, `:access_disabled`; and
an HTTP error of a model's provider, as
`{:anthropic, {:http, 401, %{…}}}`.

**What to do in the meantime.** Read the term: its first word names what
was refused and the rest why. `agent_required` lists the agents of depth 0,
one of which `--agent` names; `access_disabled` asks for an `[access]`
table ([how to run the server](how-to-run-the-server.md)); an HTTP status
is the provider's answer, often a missing or wrong key
([how to log in to a provider](how-to-log-in-to-a-provider.md)).

## 2. The codex-like preset's `cursor` model has no program

Read in the code.

**What happens.** `priv/presets/codex-like/omunculus.toml` declares the
model `cursor` with `command = ["./bridges/cursor-agent"]`, a program the
preset does not ship. A project from that preset loads, and its agents run
on `fake`; an agent put on `cursor` fails each run, since the program is
not there.

**What to do in the meantime.** Leave the agents off `cursor`, or point its
`command` at a program of your own that speaks the sandbox NDJSON protocol
([the TOML](config.md#the-adapters)).

## 3. Unresolved permissions can cycle through internal text replies

Seen running, in the design-to-build task of
[Equivalent Exchange](../eval/README.md).

**What happens.** An intermediary replies that a client question was already
sent, although no client request was recorded. The permission origin remains
unresolved. When its receiver ends without resolving it, automatic escalation
can select the same intermediary again. The cycle makes model calls without
advancing the work.

**What to do in the meantime.** Inspect the recorded request origins and
replies, interrupt the cycle and preserve its events. Have the front desk
present the actual pending permission through its configured client route.
An optional steward overlay can recover a saved copy of the cycle; the
default agency still has it.
[How to measure course recovery](how-to-measure-course-recovery.md) runs it.

## 4. The console does not show an agent's reply as it arrives

Seen running, on the console's chat page.

**What happens.** Your message shows as soon as it is sent, but the agent's
reply does not: its turn takes no room in the timeline although the reply is
recorded. Opening the conversation again from the conversations page shows
every reply.

**What to do in the meantime.** Press BACK and open the conversation again
from the conversations page, or read the reply in the mailbox.

## 5. A message in an empty conversation opened from the list is refused

Seen running, on the console's chat page.

**What happens.** A conversation that has no message yet names no agent. Opened
from the conversations page, the message you send to it carries none, and the
server refuses it; the console shows `invalid`.

**What to do in the meantime.** Start the conversation with NEW CONVERSATION,
which asks whom it is with.
