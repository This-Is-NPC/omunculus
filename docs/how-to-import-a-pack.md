# How to import a pack

**The question:** how do I add a team that comes as a folder to my project?

This page is enough on its own for a pack that needs no tool the project
lacks. What a pack holds and how teams talk to each other is
[packs](packs.md); each pack's own README says what it needs.

## Before you start

- A project whose `omunculus.toml` loads
  ([how to start a project](how-to-start-a-project.md)).
- The pack's folder. The checkout ships `packs/sales-desk`,
  `packs/dream-team` and `packs/design-team`.
- `<checkout>` is a placeholder for the folder of the omunculus checkout.

## Steps

1. Ask the pack what it needs: without `--models`, `pack` names the roles
   that need a model and imports nothing.

   ```console
   $ <checkout>/bin/omunculus pack --path <checkout>/packs/sales-desk
   models needed for: team
   sales-desk 0.2.0: Front office of a web agency: …
   agents: front-desk, project-manager, seller
   …
   ```

   The output is cut where `…` stands. After the roles, it says what the pack is, runs and needs: its
   description, agents, executables, logins, secrets and job templates.

2. Import it, each role on a model of the project. A pack that names
   logins takes `--auth provider=login` pairs the same way, and `--depth n`
   moves the team `n` depths below its own.

   ```console
   $ <checkout>/bin/omunculus pack --path <checkout>/packs/sales-desk --models team=fake
   imported sales-desk
   ```

   The pack is written to `[[packs]]`, and the files of its `workspace/`,
   when it has one, that the project's workspace lacks are copied in
   (the sales desk has none). The first line of
   `omunculus.toml` is now, the checkout's path shortened to `…`:

   ```toml
   packs = [ { models = { system = "fake" }, path = "…/priv/packs/system" }, { auth = {  }, models = { team = "fake" }, path = "…/packs/sales-desk" } ]
   ```

3. Check that its agents and workflows are there.

   ```console
   $ <checkout>/bin/omunculus config
   {"root":"/tmp/omu-howto/first",…,"sections":{…,"agents":{"auditor":1559,"concierge":8870,"front-desk":4194,"project-manager":7078,"refiner":1851,"reviewer":1249,"seller":5988,"steward":1839,"worker":3526},…,"packs":{"sales-desk":987,"system":452},…,"workflows":{"delivery":220,"engagement":218,"sale":188},…}}
   ```

   The output is cut where `…` stands. The sales desk brought the agents
   `front-desk`, `project-manager` and `seller` and the workflows
   `engagement` and `sale`.

## What can go wrong

- A pack that `requires` a tool no `[tools] path` holds is refused, and
  the file stays as it was:

  ```console
  $ <checkout>/bin/omunculus pack --path <checkout>/packs/design-team --models team=fake
  pack design-team requires tools the project lacks: bash (the codex-like preset's tools (priv/presets/codex-like/tools)); deploy_preview (the dream-team pack (packs/dream-team)); add a [tools] path that holds them or import the pack that brings them
  ```

  Add `<checkout>/priv/presets/codex-like/tools` to `[tools] paths`, and
  import the dream team first.
- A team a pack brings at depth 0 shares it with the agents already there:
  `send` then names the agent a message is for with `--agent`.

## Where to go next

- [How to share a pack](how-to-share-a-pack.md): a pack as one file, to
  send and install without a folder.
- [Packs](packs.md): what a pack holds, the system team, and how a team is
  composed with others.
- [The TOML](config.md), for the `[[packs]]` entry the import wrote.
