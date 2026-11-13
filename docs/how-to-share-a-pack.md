# How to share a pack

**The question:** how do I send a team to someone as one file, and how do
they install it?

This page stands on its own for a pack that needs no tool the receiver's
project lacks. What a pack holds is [packs](packs.md); importing a folder
is [how to import a pack](how-to-import-a-pack.md).

## Before you start

- A pack whose `pack.toml` has a `[pack]` header with `name`, `version`
  (semver), `description` (one line: what the team does) and `omunculus`
  (the least omunculus it runs on):

  ```toml
  [pack]
  name = "sales-desk"
  version = "0.2.0"
  description = "Front office of a web agency: …"
  omunculus = ">= 0.3.0"
  ```

- The receiver has a project whose `omunculus.toml` loads
  ([how to start a project](how-to-start-a-project.md)).
- `<checkout>` is a placeholder for the folder of the omunculus checkout.

## Steps

1. Export the pack. The file is `<name>-<version>.omupack` in the working
   directory, or the one `--out` names.

   ```console
   $ omunculus pack export --path <checkout>/packs/sales-desk
   /tmp/omu-share/p2/sales-desk-0.2.0.omupack
   sha256 dc85386bf5fb80fdb7c3635eb435e162f666f940945bc283583fb43d728d1c5b
   ```

   The file is a gzip tar of the pack's folder, without `.git`, `_build`
   and `.omunculus`, and an `omupack.toml` with the header and the
   `sha256` and `mode` of every file. Send it by e-mail, a drive or a
   chat, and say the sha256 if the receiver should check the copy.

2. The receiver reads what the pack is before installing it. Without
   `--models`, `pack --file` writes nothing: it says which roles need a
   model and what the pack is, runs and needs. `--file` takes a path or an
   `https` URL.

   ```console
   $ omunculus pack --file sales-desk-0.2.0.omupack
   models needed for: team
   sales-desk 0.2.0: Front office of a web agency: …
   agents: front-desk, project-manager, seller
   runs these executables: tools/_proposal/handoff.py, …, tools/wait_client/tool.toml
   needs these logins: none
   needs these secrets: none
   job templates: none
   ```

   The output is cut where `…` stands. The executables line lists every file of the pack's `tools/`: they run
   on the receiver's machine, so read it.

3. Install it, each role on a model of the project, and a login for each
   provider the card names (`--auth provider=login`). `pack` checks every
   hash, extracts to `.omunculus/packs/<name>-<version>/` beside the
   project's store and imports from there as it does for a folder.

   ```console
   $ omunculus pack --file sales-desk-0.2.0.omupack --models team=fake
   installed sales-desk 0.2.0 in /tmp/omu-share/p2/.omunculus/packs/sales-desk-0.2.0
   imported sales-desk
   ```

   Installing the same file again changes nothing:

   ```console
   $ omunculus pack --file sales-desk-0.2.0.omupack --models team=fake
   sales-desk 0.2.0 is already in /tmp/omu-share/p2/.omunculus/packs/sales-desk-0.2.0
   imported sales-desk
   ```

4. To take a newer version, add `--upgrade`. The `[[packs]]` entry then
   points at the new folder. The old folder stays until you remove it by
   hand; there is no command to remove a pack.

   ```console
   $ omunculus pack --file sales-desk-0.3.0.omupack --models team=fake
   cannot import sales-desk-0.3.0.omupack: sales-desk is already imported at version 0.2.0 from /tmp/omu-share/p2/.omunculus/packs/sales-desk-0.2.0; installing 0.3.0 replaces it: add --upgrade to do that
   $ omunculus pack --file sales-desk-0.3.0.omupack --models team=fake --upgrade
   installed sales-desk 0.3.0 in /tmp/omu-share/p2/.omunculus/packs/sales-desk-0.3.0
   upgraded sales-desk from 0.2.0; the old folder /tmp/omu-share/p2/.omunculus/packs/sales-desk-0.2.0 stays until you remove it by hand
   imported sales-desk
   ```

An agent can propose the same install: `propose_pack` takes `file` as it
takes `path`, and the request the person answers carries the summary of
step 2.

## What can go wrong

- `… does not match the hash in the manifest`, `… is in the archive and not
  in the manifest`, `… is in the manifest and not in the archive`: the file
  changed or broke on the way. Ask for it again.
- `unsafe entry …`: the archive holds an absolute path, a `..`, a link or
  a device. Nothing was written. Do not install it.
- `needs omunculus >= … and this is …`: the pack asks for a newer
  omunculus. Update ([how to install, update and remove
  omunculus](how-to-install-and-remove.md)) or ask for an older version.
- `… holds a different … <version>`: the folder of that version in
  `.omunculus/packs` is not the file's. A version names one set of files:
  the author must publish a new version number.
- `only https URLs are fetched`: download the file and give its path.
- `[pack] <key> is missing or not valid` on export: the header of
  `pack.toml` lacks that key.

## Where to go next

- [Packs](packs.md): what a pack holds and how teams compose.
- [The command line](cli.md): `pack` and `pack export`.
