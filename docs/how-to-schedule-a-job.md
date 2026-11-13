# How to schedule a job

**The question:** how do I have an agent, a workflow or a tool run on a schedule?

This page stands alone for the command line. The Console and the mailbox
reach the same jobs through [the server](server.md#jobs).

## Before you start

- A project whose `omunculus.toml` loads
  ([how to start a project](how-to-start-a-project.md)), with an agent of depth 0.
- A `[jobs]` table. It has no default, so without it the project has no jobs:

  ```toml
  [jobs]
  max_parallel = 2
  min_interval_minutes = 5
  max_jobs = 50
  missed = "skip"
  lateness_seconds = 60
  failures_before_pause = 3
  agent_may_create = false
  ```

  Each key is in [the TOML](config.md#jobs).
- The host's time zone database (`/usr/share/zoneinfo`).
- `<agent>` is a placeholder for an agent of depth 0.

## Steps

1. Create the job. The schedule is a 5-field cron expression, `every 30m`,
   `every 2h` or `daily at 09:00`, read in the time zone given.

   ```console
   $ omunculus jobs create --name morning --agent <agent> \
       --message "Summarize yesterday's work." \
       --schedule "daily at 07:00" --timezone Europe/Paris
   created morning
   ```

   The job runs as you. `--owner <name>` names an `[accounts]` name or an agent;
   `--delivery owner_inbox` sends each fire's final reply to the owner's mailbox.

2. Read it, with the next fires of its schedule:

   ```console
   $ omunculus jobs show --name morning
   ```

   The output starts `morning [active], version 1` and lists what it runs, the
   schedule, `next fires:` with three instants in UTC, who it runs as, and its
   totals.

3. Change it. `edit` bumps the version and keeps the history; an empty value
   clears a field.

   ```console
   $ omunculus jobs edit --name morning --schedule "daily at 08:00"
   $ omunculus jobs pause --name morning --reason "holiday"
   $ omunculus jobs resume --name morning
   ```

4. Before creating a job, preview it: the next three fires of a schedule and an
   estimate of what a fire costs.

   ```console
   $ omunculus jobs preview --schedule "daily at 07:00" --timezone Europe/Paris --agent <agent>
   next fires: 2026-11-14T06:00:00Z, 2026-11-15T06:00:00Z, 2026-11-16T06:00:00Z
   cost per fire: no estimate (no fires of jobs or runs of the agent <agent> to estimate from yet, so there is no estimate)
   ```

   The estimate is the mean cost of the target's latest fires in jobs or, with
   none, of its latest runs, at the models' prices. With no history there is no
   figure, and the sentence says so.

5. Run it once now with `jobs run --name morning`, copy it as a draft with
   `jobs duplicate --name morning --as evening`, read what happened to it with
   `jobs history --name morning`, and remove it with `jobs archive --name
   morning`; the history stays, and the name is free again.

## What happens when it is due

The server runs one scheduler for each project, checking the clock every second.
Each slot of the schedule becomes a fire, recorded in the job's history:

- **Condition.** A job with a `--condition` tool first calls it, as the owner and
  with no model. The tool prints JSON: `{"run": true}` goes on; `{"run": false,
  "reason": "..."}` records the fire as `skipped` and spends nothing; adding
  `"pause": true` also pauses the job with that reason, as when a subscription is
  cancelled. A tool that fails or prints anything else skips the fire with that as
  the reason.
- **Run.** The fire sends the job's message to its agent, or opens a root work for
  its workflow, or calls its tool, as the owner. Each fire opens a conversation of
  its own, or goes to the job's `--conversation_id`. The fire is `running`, then
  `succeeded` or `failed`, with the conversation, the runs, the duration, the model
  calls, the tokens and the dollars at the models' prices. With `--delivery
  owner_inbox` the replies are its `message`.
- **At most `max_parallel` fires of a project run at once.** The others wait, due.
- **Late.** A fire that did not start within `lateness_seconds` of its time is
  marked `late`, and its owner gets a request saying so.
- **Down.** The slots that passed while the server was down follow `[jobs] missed`:
  `skip` records them as one `missed` fire with the first and last slot and how
  many there were; `run_once` does the same for all but the latest and runs that
  one. The job's totals count each missed slot. A fire left running when the server stopped fails.
- **Failures.** After `failures_before_pause` fires in a row fail, the job is
  paused with the reason and its owner told. `jobs resume` starts counting again.
- **End date.** After `--end_at` the job moves to `ended`.

A job's owner needs the capabilities its fires use (`conversation.create` and
`conversation.send`, as for any message); an agent owner acts as the principal
`agent:<name>`, which needs a membership of its own. A fire that is refused
fails, and counts toward the pause. The workspace of a job applies to a workflow
target; an agent target works in the default one.

## Having an agent propose it

An agent with `propose_job` makes the same job from a conversation: "every
morning at 7:00 summarize …". The proposal is a request to the person with the job
in words and its next fires, and the options `approve`, `edit` and `deny`.
Approving creates the job, owned by whoever approves it unless an owner was named.
With `agent_may_create = true` the job is made at once, owned by the agent.
Nothing creates or changes a job from a run that a job's fire opened.

## Having a pack bring it

A pack can carry job templates, `[jobs.<name>]` tables in its `pack.toml`
([packs](packs.md#job-templates)). Importing the pack creates each as a
job named `<pack>.<name>`, owned by you, `active` or `proposed` as the
template says; importing again creates only the ones you lack. Read them
with `omunculus jobs list`; start a `proposed` one with `jobs resume`.

## If it fails

| You see | Because |
| --- | --- |
| `omunculus.toml has no [jobs] table, so the project has no jobs` | add `[jobs]` |
| `the schedule fires every 60 seconds; [jobs] min_interval_minutes allows no less than 300` | a faster schedule than the policy allows |
| `<name> is not a time zone of the host's database` | the zone is not in `/usr/share/zoneinfo`; use an IANA name |
| `a job named <name> exists` | names are unique among jobs that are not archived |
| `the project holds <n> jobs, the most [jobs] max_jobs allows` | archive one, or raise the limit |
| `cannot import <path>: job template <name>: …` | the project's policy refuses the pack's template; the import wrote nothing |
| `a run that a job's fire opened may not create or change jobs` | create it from a person's message |
| A fire is `failed` with `the server stopped while the fire ran` | the server stopped during it; the next fire runs as usual |
| A fire is `skipped` with `the condition failed: ...` | the condition tool failed or did not print `{"run": true|false}` |

## Next

[The TOML](config.md#jobs) for the policy, [tools](tools.md#scheduled-jobs) for
`jobs` and `propose_job`, [the server](server.md#jobs) for the routes, and
[the design](design.md#the-scheduler) for how fires are claimed and run.
