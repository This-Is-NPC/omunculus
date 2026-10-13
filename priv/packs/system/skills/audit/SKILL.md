---
name: audit
description: Go through the project's config for what is loose or left over — grants beyond what an agent's work needs, agents that never run, workflows nothing goes through, secrets bound to no login, models without a login — and propose cutting each, one change at a time.
---

# Auditing the project

Read the project first; find before you cut. A project's setup is longer
than one call returns, so read it in parts:

- `config` without arguments gives an index: each section's items with
  their sizes. Read each section with `section` (`workflows`, `models`,
  `auth`, `secrets`, `workspaces`, `policy`, `access`, `packs`), and each
  agent with `item` (`agents.<name>`): what the config runs, the pack it
  comes from, and what the file writes for it.
- `overview` without arguments gives each place and depth, its workflows
  and stages and the agents they go to; with `agent`, where that agent
  runs and what it has there, each tool classified.

Go through every section and every agent before you judge one.

## What to look for

- **Grants past the work.** An agent whose `tools` hold what its text never
  asks it to do, a tool in `human` that it could ask for instead, a whole
  group where one tool of it is used. Each is a door left open.
- **What never runs.** An agent `overview` shows idle in every place, a
  workflow in `unused_workflows`, a workspace no policy or agent names.
- **What cannot run.** A model whose `provider` names no login, a tool's
  secret bound to no provider, a stage whose agent its depth does not
  allow.
- **What says one thing and does another.** An agent's text naming a tool
  it does not have, or a workflow it cannot reach.

## How to cut

1. Name the finding to yourself with its evidence: the item, the key, what
   `config` or `overview` shows.
2. Propose the change with `propose_config` (see configure): the item's
   whole value as it should be written, and a reason that says what was
   found and what the cut changes, so the person can decide.
3. One finding, one proposal. What you are not sure of, ask the person
   about instead of proposing.

## Cutting one name, and what a pack brings

- A group granted where one of its members is past the work: cut that
  member with the agent's `deny`, keeping the group, rather than dropping
  the group or saying it cannot be cut.
- An agent or workflow a pack brings: cut it in the project's file, which
  overrides the pack's item key by key — propose `agents.<name>` with
  only the key that changes, as the configure skill shows. For example,
  a pack's agent granted `fs.write` whose work only reads:

  ```json
  {"item": "agents.researcher", "value": {"deny": ["fs.write"]},
   "reason": "researcher only reads: its runs never wrote a file"}
  ```

  What the project's file cannot reach — a pack's own tools, skills and
  files — say to the person.
