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
while the file is as it was when proposed.

Their skills:

- `team-design`: a new team, written as a pack under `packs/<name>/` of
  the workspace, with the tasks that show it works.
- `team-composition`: teams fitted together — at which depth each works,
  on which models, and what one tells another.
- `configure`: any other change to the config, one item at a time.
- `audit`: the auditor's — grants past the work, what never runs or cannot
  run, each cut proposed on its own.
- `refine`: the refiner's — what the last runs show went wrong, its cause
  in the config, and the change, with the runs that show it.
