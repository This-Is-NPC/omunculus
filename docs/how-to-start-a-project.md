# How to start a project

**The question:** how do I get a project that answers a first message?

This page is enough on its own for a project that runs without a network,
on the `fake` model. Putting the agents on a real model is
[how to log in to a provider](how-to-log-in-to-a-provider.md).

## Before you start

- omunculus installed ([how to install](how-to-install-and-remove.md)).
  Working from a checkout instead, run `bin/omunculus` in its place
  ([the design](design.md#8-building-and-checking)).
- Linux with Bubblewrap ([Requirements](../README.md#requirements)).

## Steps

1. Make an empty folder for the project and go into it.

   ```console
   $ mkdir -p ~/projects/first && cd ~/projects/first
   ```

2. Copy a preset in. This writes `omunculus.toml`, the one file every
   other command reads.

   ```console
   $ omunculus preset default
   preset default applied
   ```

   Omunculus bundles three presets:

   | Name | What it is |
   | --- | --- |
   | `default` | a concierge at depth 0, a worker and a reviewer below it, on the `fake` model, no shell; it imports the [system team](packs.md#the-system-team) |
   | `codex-like` | a Codex-shaped ceiling, with a `bash` tool |
   | `pi-like` | a Pi-shaped ceiling, with an Anthropic login declared |

   A preset of your own is a folder holding `omunculus.toml`:
   `omunculus preset <name> --from <folder>`.

3. Send the first message. The default preset has several agents at
   depth 0 — the concierge and the system team's steward, auditor and
   refiner — so the message names the one it is for.

   ```console
   $ omunculus send "count to 5" --agent concierge
   fake model: You are the project concierge; you talk with the person and hand work to the agents under ## Agents.
   ```

   A send prints what the run gave you once it has finished: the agent's
   reply. The `fake` model answers with the first line of its prompt, so
   the run needs no network.

4. Read what the run did.

   ```console
   $ omunculus runs
   1 runs, newest first.

   run e4c093140ccb8e932b1c29eb4d6e21d0 · concierge · depth 0 · 2026-10-13T17:02:09.793268Z · 0 s · no work · via send
     ended: stopped without end
     calls: 0
     model: 1 replies · 0 tokens in (0 cached) · 0 out
   ```

5. Read the prompt the run was given.

   ```console
   $ omunculus prompt
   You are the project concierge; you talk with the person and hand work to the agents under ## Agents.
   …
   ## Message
   count to 5
   ```

   The middle is cut here: it holds the concierge's text, the agents it may
   hand work to, its tools, the skills it has and the workspace.

## What can go wrong

- `send` without `--agent` is refused:

  ```console
  $ omunculus send "count to 5"
  several agents have depth 0: auditor, concierge, refiner, steward; name one with --agent
  ```

  The list is the agents of depth 0; name one with `--agent`.
- A command run in a folder without `omunculus.toml` is refused with
  `` no config at <path>; run `omunculus preset <name>` ``.
- A run that stopped without `end` is retried up to `[policy] max_retries`
  times when it holds a work ([the cycle](cycle.md#a-run-without-a-report)).

## Where to go next

- [How to log in to a provider](how-to-log-in-to-a-provider.md), to run
  the agents on a real model.
- [How to import a pack](how-to-import-a-pack.md), to add a team.
- [How to run the server](how-to-run-the-server.md), to open the apps.
- [The TOML](config.md), for what the file can hold.
