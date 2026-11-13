---
name: refine
description: Read how the project's last runs went — where an agent stopped without ending, retried, was refused a tool, skipped a step, looped or spent much — find the cause in its text, tools or workflow, and propose the improvement, one change at a time, with the runs that show it.
---

# Refining the teams from their runs

Read before you judge: `runs` sums up the project's last closed runs; `runs`
with `run` gives one call by call; `config` with `item` `agents.<name>` gives
what an agent was told, and `overview` with `agent` what it had where it
ran; without arguments, each lists what there is to read. `config` with
`section` `tools` lists every tool the project has, those an agent lacks
too: check there before you say a tool does not exist.

## What to look for

- **Stopped without end.** The model gave up or answered in text where a
  tool was due: its text does not say what ends its turn, or the tool it
  needed was not its own.
- **Retries and breaks.** The same work run again and again, or broken:
  what it lacked — a file, an answer, a tool — and who should have given it.
- **Refused calls.** A tool an agent reached for and did not have: either
  its text sends it there and should not, or its work needs the tool and
  it should have it, or ask for it.
- **Skipped steps.** An agent that went past what its role requires — no
  review, no plan, no question before building. A step that must not be
  skipped belongs in a workflow stage or a tool's refusal, not only in
  more words of its text.
- **A request made by hand again and again.** The same message to the same
  agent or workflow, from the person, in several runs, at a rhythm: a
  schedule would do it. See *Proposing a job* below.
- **Loops and waste.** The same call repeated, a file read again and
  again, a reply far longer than the work needed, a model costlier than
  the job.

## How to propose

1. Find the pattern in more than one run when you can; name the runs.
2. Find its cause in the config: the agent's text, its tools, its
   workflow, the model it runs on.
3. Propose the change with `propose_config` (see configure), with a reason
   that says what went wrong and what the change makes go right, and `runs`
   holding the ids of the runs that show it, as `runs` prints them. The
   tool refuses an id that is not one of the recent runs and shows the
   person the runs cited; a change that no run shows, such as granting a
   tool the work needs, cites none. One cause, one proposal.
4. For an agent or workflow a pack brings, an item of the project's own
   with the same name overrides the pack's key by key: propose only the
   keys that change. What should change in the pack itself, tell the
   person.

What the runs do not show, ask the person about; never change what
worked to make it look tidier.

## Proposing a job

A request the runs show the person making by hand, on a rhythm — the same
message to the same agent or workflow, run after run — is a candidate for a
scheduled job. Propose it with `propose_job`, only when you see it in at
least two runs: `runs` holds the ids of those runs, as `runs` prints them,
and the `reason` says what the person keeps asking and why a schedule
fits. Take the message, the target and the rhythm from the runs; read the
time zone and the owner from the person, never guess them. The job is not
created until the person approves it; `propose_job` refuses a name taken or
a schedule the project does not allow, and says why. One recurring request,
one proposal. A request seen once is not a rhythm: ask the person instead.
