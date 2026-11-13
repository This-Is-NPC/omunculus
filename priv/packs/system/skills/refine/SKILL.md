---
name: refine
description: Read how the project's last runs went — where an agent stopped without ending, retried, was refused a tool, skipped a step, looped or spent much — find the cause in its text, tools or workflow, and propose the improvement, one change at a time, with the runs that show it.
---

# Refining the teams from their runs

Read before you judge. Start with `process`: it mines the event log and
gives the measured facts, so you do not read runs one by one to find a
pattern. It gives each workflow's fitness (the share of works that follow
the stages the config declares) and the deviations by kind with their cases,
the most frequent variants, each activity's count, duration, cost and
refusals and, with `support` and `confidence`, the rules the works that
ended done keep and the cancelled ones break. Every case names its work,
conversation and runs. Then `runs` sums up the project's last closed runs;
`runs` with `run` gives one call by call; `config` with `item` `agents.<name>` gives
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

## What the numbers mean

- **Low fitness, one kind of deviation.** Works skip, repeat or leave a
  stage: a gate that refuses the move beats more words in a text. The
  deviation's cases say which works.
- **A rule the done works keep and cancelled ones break.** A step that
  succeeding works always take and failing ones skip: the candidate for a
  stage, or a tool's refusal, that makes it happen. Give `support` and
  `confidence` as numbers from 0 to 1 and read the rules that most
  cancelled works break.
- **An activity with many refusals, or a high p90 or cost.** The agent
  reaches for what it lacks, or the step is slow or dear: read its runs.
- **A variant far more frequent than the declared workflow.** The work
  really goes that way; the config should say so or stop it.

## How to propose

1. Run `process` first and find the pattern in its numbers; read the runs
   its cases name; cite the numbers and the cases in the reason.
2. Find its cause in the config: the agent's text, its tools, its
   workflow, the model it runs on.
3. Propose the change with `propose_config` (see configure), with a reason
   that says what went wrong and what the change makes go right, and `runs`
   holding the ids of the runs that show it, as `runs` prints them. The
   tool refuses an id that is not one of the recent runs and shows the
   person the runs cited; a change that no run shows, such as granting a
   tool the work needs, cites none. One cause, one proposal.
   Name the metric the change should move in `evidence`: `metric`, in the
   words `process` uses (fitness of a workflow, refusals of a tool, the
   cost of an activity), `before`, its value in `process` now, `expected`,
   what it should be after, and `workflow`, the workflow to draw. The
   harness mines the as-is BPMN from the log and draws the to-be from the
   config as it would be once the change is applied, keeps both as
   artifacts of the conversation and names them in the request; you never
   draw a diagram. Without a work that went through the workflow in the
   log there is no as-is, and the tool says so.
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
