# How to install, update and remove omunculus

**The question:** how do I get omunculus and its apps onto this machine, keep
them current, and take them off again?

This page is enough on its own. It ends with the server running as your
user service, the apps open, and the one command that removes the packages.
Starting a project and logging in to a provider are their own pages.

The release does not exist yet. Outputs below that come from a release are
marked as expected, not observed; `<version>` is a placeholder for a
release number such as `0.1.0`.

## Before you start

- Arch Linux on x86_64 with a systemd user session (Omarchy qualifies).
  Only Arch packages are released.
- `curl` and `sudo`.
- For the apps: a Wayland session
  ([Requirements](../README.md#requirements)). The package pulls
  `quickshell` and `qt6-declarative` in.
- Optional, each for one feature: `deno` (code mode and `browser_check`),
  `chromium` (`browser_check`), `python` (`lsp`).

## Steps

1. Install the latest release.

   ```bash
   curl -fsSL https://raw.githubusercontent.com/This-Is-NPC/omunculus/master/install.sh | bash
   ```

   The script downloads two packages, `omunculus` (the server, the command
   line, the builtin tools and the system pack) and `omunculus-apps` (the
   console, the mailbox and the studio), checks both against the
   release's `SHA256SUMS`, and installs them in one `pacman -U`. It asks
   for your password through `sudo`. Expected last lines:

   ```console
   omunculus: installed. Next: omunculus setup
   omunculus: take it off again with: sudo pacman -R omunculus omunculus-apps
   ```

   Variables, all optional:

   | Variable | Effect |
   | --- | --- |
   | `VERSION=<version>` | install that release, not the latest |
   | `APPS=0` | install `omunculus` only, without the apps |
   | `DRY_RUN=1` | download and verify, print the `pacman` command, install nothing |
   | `REPO=<owner>/<name>` | read releases of another repository |
   | `BASE_URL=<url>` | read the release files from this folder or URL |

2. Set it up.

   ```bash
   omunculus setup
   ```

   `setup` writes `~/.config/omunculus/server.toml`, the server registry
   ([the server](server.md)), when it is missing, says which values it
   wrote, and enables and starts the user service
   (`systemctl --user enable --now omunculus`). Run again, it changes
   nothing that exists and says so. The package never writes into your
   home directory; this command does.

3. Check that the server runs.

   ```bash
   systemctl --user status omunculus
   ```

   Expected: `active (running)`.

4. Open an app. The package puts a launcher and a menu entry for each:

   ```bash
   omunculus-console
   omunculus-mailbox
   omunculus-studio
   ```

   What each shows is [the screens](screens.md). The console opens on a
   project the server serves, so [start a project](how-to-start-a-project.md)
   first and list it in `server.toml`
   ([how to run the server](how-to-run-the-server.md)).

5. Add domain packs when you want them. The packages carry the system pack
   only; the packs of the repository (`sales-desk`, `dream-team`,
   `design-team`) are folders you fetch from the repository and import
   into a project. [How to import a pack](how-to-import-a-pack.md) shows
   the command, `omunculus pack <path>`.

## Update

```bash
omunculus update --check
omunculus update
```

`--check` asks GitHub for the latest release (one request, no data about
you) and says whether it is newer than the running version and what an
update would do, changing nothing. `update` downloads the packages the
release lists (the apps only when `omunculus-apps` is installed), checks
their checksums, installs them with `sudo pacman -U`, which asks on the
terminal, and restarts the user service when it is active.

Running `install.sh` again does the same by hand.

After a manual `pacman -U` or `pacman -Syu` upgrade, restart the service
yourself so it runs the new version; pacman prints the command:

```bash
systemctl --user restart omunculus
```

## Remove

Stop the service first, as each user who ran it. pacman cannot reliably stop
another user's service, so it only prints this command before it removes:

```bash
systemctl --user disable --now omunculus
sudo pacman -R omunculus omunculus-apps
```

Without the first line the server keeps running from deleted files and
leaves a dangling enable link in `~/.config/systemd/user`. The second line
removes every file the packages installed. It stays:

- `~/.config/omunculus/server.toml`, which `setup` wrote;
- your projects, with their `omunculus.toml` and their data, wherever you
  keep them.

Delete those yourself if you want them gone.

## Troubleshooting

- **`there is no pacman here`** or **`only an x86_64 package`**: the
  release is for Arch on x86_64 only. Run omunculus from a checkout
  instead ([the design](design.md#8-building-and-checking)).
- **`found no published release`**: the repository has no release the
  script can read, or GitHub is unreachable. Name one with
  `VERSION=<version>`, or check the network.
- **`does not match the release's SHA256SUMS; nothing was installed`**:
  a download was cut or altered. Run the script again; if it repeats, do
  not install and report it.
- **`omunculus: command not found` after install**: open a new shell; the
  launcher is `/usr/bin/omunculus`.
- **The service is not active**: `journalctl --user -u omunculus` says
  why; `omunculus setup` again re-enables it.

## Next

[How to start a project](how-to-start-a-project.md), then
[how to log in to a provider](how-to-log-in-to-a-provider.md).
