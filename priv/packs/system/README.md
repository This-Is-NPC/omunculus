# The system team

The agents that maintain an Omunculus project itself. It comes with
Omunculus: the default preset imports it, and the person talks with it by
name (`omunculus send --agent steward "…"`), apart from the teams that do
the project's work.

| Agent | Depth | Role |
|---|---|---|
| steward | 0 | keeps the project's structure: designs teams, fits them together, changes the config |
| auditor | 0 | finds what in the config is loose or left over, and proposes cutting it |
| refiner | 0 | reads how the last runs went and proposes what in the teams should change |

Every change the steward, the auditor or the refiner makes goes to the person as a request: the
config it would make is loaded first, so a change that would break the
file never reaches them, and it applies only once they approve it and only
while the file is as it was when proposed. The request goes to whoever gave the agent its work: for a root
work, the person who opened the conversation. A project that wants it to
reach another account names that account in `[accounts]` and holds the
proposals with an `[[interceptors]]` rule for the tool
([config](../../../docs/config.md#interceptors)): the change reaches that
account for review, not only whoever the request passes through.

Only the steward proposes importing a pack: the auditor and the refiner
are granted `config`, `overview`, `process` and `propose_config`, not
`propose_pack`. `process` mines the event log for measured facts — how
closely works followed their workflows, the variants, each activity's cost
and refusals, the rules done works keep and cancelled ones break — so the
refiner reasons over numbers, not run by run ([how to find what to
improve](../../../docs/how-to-find-what-to-improve.md)).
They are also granted `propose_job`: the refiner proposes a scheduled job
for a request the runs show the person making by hand, with those runs
cited, and the auditor for a routine the config says is done by hand. The
person approves it like any proposal
([how to schedule a job](../../../docs/how-to-schedule-a-job.md)).

A proposal is a patch over the file's item: a key it gives replaces the
file's, a key it leaves out stays, a key given as `null` is removed. The
request shows the person the item as the config runs it, now and as it would
run, and the runs the agent cited, which must exist. A change the person
already denied in the conversation is refused before it is asked again, and
the agent is told the reply. The agents read every tool the project has, with
its description, through `config` with `section` `tools`, whether or not
they are granted it.

Their skills:

- `team-design`: a new team, written as a pack under `packs/<name>/` of
  the workspace, with the tasks that show it works.
- `team-composition`: teams fitted together — at which depth each works,
  on which models, and what one tells another.
- `configure`: any other change to the config, one item at a time —
  including one member of a granted group cut with `deny`, and an agent or
  workflow a pack brings changed by that item's keys in the project's file.
- `audit`: the auditor's — grants past the work, what never runs or cannot
  run, each cut proposed on its own.
- `refine`: the refiner's — what `process` and the last runs show went
  wrong, its cause in the config, and the change, with the numbers, cases
  and runs that show it, the metric it should move and the BPMN pair, as-is
  and to-be; and when to propose a scheduled job.
