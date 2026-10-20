---
name: team-design
description: Design a new team of agents for a job and write it as a pack — its agents, depths, workflow, tools, the rules its workspace starts with, what it needs on the machine and the tasks that show it works.
---

# Designing a team

A team is a pack: a folder anyone can import into a project. Write it in
the workspace under `packs/<name>/`, then propose importing it with
`propose_pack` (see team-composition).

## Start from the job

Ask the person what the team is for, who it answers to, and what it must
never do without them. Base its roles on how people do that job well — a
known way of organising it — and say which one you followed.

## The pack's folder

```text
pack.toml      [pack] name, version, description, roles, auth
               [agents.<name>] [workflows.<name>] [secrets.<tool>]
               [[mcp.servers]] [policy.depth.<n>]
README.md      what the team is, its agents, what it needs to be imported
tools/         tools of its own: a folder per tool, tool.toml and its command
skills/        skills of its own: a folder per skill, SKILL.md
workspace/     the files a workspace of the team starts with, AGENTS.md first
environment/   what the team needs on the machine, which the person runs
tasks/         the tasks that show the team works
```

- Each agent has a `depth`, a `model` that is one of the pack's `roles`
  (never a model's name: the importer maps roles to their models), a
  `text` and its `tools`. An agent that hands work to the depth below needs `work`
  and `delegate` (the step `work` runs to hand it down), `reopen` to
  send it back and `retire` to drop one that broke and is no longer
  wanted; one that hands work up when done needs `done`,
  `continue` and `comment` (its report becomes a comment), and `break` to
  stop with what is missing. A tool's manifest names the steps it runs
  (`chains`); the agent needs each of them.
- Depths start at 0 for the agent the team answers through. A team made
  for depth 0 can be imported deeper: the importer moves it down.
- A workflow (`[workflows.<name>]`, its `steps` each a `name` and an
  `agent`, all of one depth) puts a work through the same stages — build,
  check, release. The agent that hands the work down names it (`workflow`
  in `work`, in place of `agent`), and the agent's text says which; a
  depth with `[policy.depth.<n>] workflows = [...]` takes works only
  through those. Another team's workflow can share the depth: each team's
  agent names its own. Stage agents that only work in the workflow have
  `workflow_only = true`.
- What only the person may give an agent goes in its `human` list. A
  decision that is the person's — a discount, a contract, an approval —
  the agent asks for with `ask`; the project's `[policy] request_routes`
  resolves its receiver. Optional `to` names a logical responsibility
  such as owner, which the project must configure. Permission requests
  use `request_access`, including `kind = "resource"` for sandbox capabilities.
  Receivers use `reply` or `escalate`; `break` only stops failed work.
- A tool the team uses that the pack does not bring goes in
  `[pack.requires]`, with where to get it as text (another pack, a
  preset's tools): loading the config refuses the pack while the project
  lacks it.
- A tool's secrets name providers (`[secrets.<tool>]`, each secret a
  provider listed in `[pack] auth`); the importer maps them to its logins.
  `[pack] auth` lists those providers and nothing else: the login a model
  runs on is the project's, never the pack's.

## Texts that work at any depth

Write each agent's text for whoever hands it work — the person, or an
agent of the team above — not for the person alone: "the one who asked".
An agent that needs something from above stops and says what (break);
the one above answers by sending the work back (reopen).

## Show that it works

A pack is not done without its tasks. Under `tasks/<scenario>/<task>/`, in
the eval's format: `instruction.md` (what the person says), `task.toml`,
`workspace/`, a `check` and its `solution/`. Cover what the team must do,
and what it must refuse or bring back to the person.
