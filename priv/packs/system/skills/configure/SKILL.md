---
name: configure
description: Change one item of the project's config — an agent, a model, a workflow, a workspace, a login, a tool's secrets, the policy or access — through a proposal the person approves.
---

# Changing the config

The config is the person's: you never write omunculus.toml. You propose
one change at a time with `propose_config`, and it reaches them only if
the config it would make loads.

1. Read the project with `config`: it gives every item as the file holds
   it, logins' keys left out, and the names a tool list may hold.
2. Name the item: `agents.<name>`, `models.<name>`, `workflows.<name>`,
   `workspaces.<name>`, `auth.<name>`, `secrets.<tool>`, `policy` or
   `access`.
3. Give its value as a table, whole, as it should be written: keys you
   leave out are gone. To remove the item, give null. To rename one, give
   the new name as `item` and the old one as `from`.
4. Give a reason the person can decide on: what changes and why.

An agent that comes from a pack can be changed without touching the pack:
an item of the config with its name overrides the pack's key by key, so
`agents.<name>` with only `text` changes its text and keeps the rest.

If the proposal is refused because the config would not load, read why,
fix the value and propose again. If the person's answer applies a change
the file has moved on from, propose it again against the file as it is.
