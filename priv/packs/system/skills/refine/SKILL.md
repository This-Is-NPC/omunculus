---
name: refine
description: Read how the project's last runs went — where an agent stopped without ending, retried, was refused a tool, skipped a step, looped or spent much — find the cause in its text, tools or workflow, and propose the improvement, one change at a time, with the runs that show it.
---

# Refining the teams from their runs

Read before you judge: `runs` sums up the project's last closed runs; `runs`
with `run` gives one call by call; `config` with `item` `agents.<name>` gives
what an agent was told, and `overview` with `agent` what it had where it
ran; without arguments, each lists what there is to read.

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
- **Loops and waste.** The same call repeated, a file read again and
  again, a reply far longer than the work needed, a model costlier than
  the job.

## How to propose

1. Find the pattern in more than one run when you can; name the runs.
2. Find its cause in the config: the agent's text, its tools, its
   workflow, the model it runs on.
3. Propose the change with `propose_config` (see configure), with a reason
   that cites the runs, says what went wrong and what the change makes
   go right. One cause, one proposal.
4. For an agent or workflow a pack brings, an item of the project's own
   with the same name overrides the pack's key by key: propose only the
   keys that change. What should change in the pack itself, tell the
   person.

What the runs do not show, ask the person about; never change what
worked to make it look tidier.
