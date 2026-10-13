# The development environment

`dev/` holds a server registry with two projects. `dev`, whose config is the default preset's agents, the system team's steward among them, on `openai/gpt-6-luna` through OpenRouter, with `[access]` roles; its root is `dev/workspace` and its store `dev/.omunculus/`, both ignored by git. `agency`, in `dev/agency/`, the agency as `eval/configs/agency.toml` composes it: the steward and the sales desk at depth 0 with the dream team and the design team below it, imported from `packs/` on the same model, their deploy logins `homologation` and `production` from `$OMUNCULUS_HOMOLOGATION_KEY` and `$OMUNCULUS_PRODUCTION_KEY`, each conversation, one client's, working in a folder of its own under `dev/agency/workspace/clients/` ([config](config.md#a-folder-per-conversation)); its workspace and store are ignored by git too. Their tools and sandbox script are the checkout's `priv/` — the agency's with the codex-like preset's `bash`, which the dream team and the design team require — and the server runs from the checkout, so the environment runs the current code. `config_test.exs` loads every file, so a change to the config format updates them in the same commit. The tasks are atomic:

| Task | Does |
| --- | --- |
| `dev:bootstrap` | creates each project's workspace, copies into the agency's the packs' `workspace/` files it lacks, as the `pack` tool does, and seeds each project's local administrator while its store does not exist |
| `dev:serve` | runs the server on `dev/server.toml`, with the variables of `.env` (`OPENROUTER_API_KEY`) in its environment and, while the dream team's environment is up (`packs/dream-team/environment/up`), `OMUNCULUS_DEPLOY` set to its sockets folder, which the agency's `[execution] write` names, and `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL`, unless `.env` sets them, your `git config` name and email, which the agency's `[execution] environment` passes to its commands, so the builders commit as you |
| `dev:console` | opens the console on the `dev` project of a running server |
| `dev:mailbox` | opens the mailbox on the `dev` project of a running server |
| `dev:studio` | opens the studio on the `agency` project of a running server (`-- --project dev` for the other) |
| `dev:reset` | deletes both projects' stores and workspaces |
| `up` | `dev:bootstrap`, then `dev:serve` unless a server already answers |

While the dev server runs, `bin/omunculus --config dev/omunculus.toml <command>` goes to it through the socket.

## Commands

```sh
mise install                    # toolchain from mise.toml
mix deps.get
mise run validate:regular       # mix test --exclude cargo --exclude sandbox
mise run validate:sandbox       # needs Linux with Bubblewrap namespaces
mise run pre-commit             # validate:boundaries, then mix format --check-formatted
mise run pre-push               # validate:regular
mix compile --warnings-as-errors
bin/omunculus preset default --from priv/presets/default
bin/omunculus send "text"
bin/omunculus serve --config server.toml
apps/kit/run console --config server.toml [--project <id>]
mise run up                     # the dev server; the apps open with dev:console, dev:studio, dev:mailbox
apps/kit/run mailbox --config server.toml [--project <id>]
apps/kit/run studio --config server.toml [--project <id>]
```
