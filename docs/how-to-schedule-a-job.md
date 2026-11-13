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

4. Run it once now with `jobs run --name morning`, copy it as a draft with
   `jobs duplicate --name morning --as evening`, read what happened to it with
   `jobs history --name morning`, and remove it with `jobs archive --name
   morning`; the history stays, and the name is free again.

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

## Next

[The TOML](config.md#jobs) for the policy, [tools](tools.md#scheduled-jobs) for
`jobs` and `propose_job`, [the server](server.md#jobs) for the routes. The
scheduler that starts the fires is not part of this page.
