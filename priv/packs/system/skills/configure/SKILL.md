---
name: configure
description: Change one item of the project's config — an agent, a model, a workflow, a workspace, a login, a tool's secrets, the policy or access — through a proposal the person approves.
---

# Changing the config

The config is the person's: you never write omunculus.toml. You propose
one change at a time with `propose_config`, and it reaches them only if
the config it would make loads.

1. Read the item with `config` and `item` (`agents.<name>`, `policy`,
   ...): its `file` is the table as the file holds it, logins' keys left
   out, and an agent's other keys are what the config runs, its pack's
   included. `config` without arguments lists the items; with `section`
   `names`, the names a tool list may hold.
2. Name the item: `agents.<name>`, `models.<name>`, `workflows.<name>`,
   `workspaces.<name>`, `auth.<name>`, `secrets.<tool>`, `policy` or
   `access`.
3. Give its value as a table, whole, as it should be written: keys you
   leave out are gone. To remove the item, give null. To rename one, give
   the new name as `item` and the old one as `from`.
4. Give a reason the person can decide on: what changes and why.

## Cutting one tool of a group

A name in `tools` may be a group, which grants all its members: `setup`
brings `config`, `overview`, `propose_config` and `propose_pack`
(`overview` with `agent` shows each group's members). To take
one member away and keep the rest, list it in the agent's `deny`, which
blocks a name whatever grants it; there is no need to drop the whole group
or to spell out the members that stay:

```toml
[agents.auditor]
tools = ["setup", "end", "skills"]
deny = ["propose_pack"]
```

## Changing what a pack brings

An agent or workflow that comes from a pack is changed without touching
the pack: an item of the config with its name overrides the pack's key by
key, so `agents.<name>` with only the keys that change writes just those
in the project's file and keeps the rest of the pack's. Its value is the
item's `file`, the table the project's file holds for it (none at first),
with the keys you change:

```json
{"item": "agents.researcher", "value": {"deny": ["fs.write"]},
 "reason": "researcher only reads: its runs never wrote a file"}
```

A key you write replaces the pack's whole: `config` shows the key as the
config runs it, so a `deny` or `tools` you write starts from that list,
with the name you add or cut. `granted` instead adds its names to the
pack's `tools`.

If the proposal is refused because the config would not load, read why,
fix the value and propose again. If the person's answer applies a change
the file has moved on from, propose it again against the file as it is.
