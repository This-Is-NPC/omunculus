# The development environment

`dev/` is your development environment, ignored by git: a server registry, `dev/server.toml`, and the project configs it names, each in a folder of its own with its workspace and store beside it. Its projects are what you want to try, and you change them without a commit. A run of the behaviour benchmark keeps the config each of its executions ran on, at `eval/results/<run>/executions/<task>/<configuration>/<n>/project/omunculus.toml`; copy the one you want under `dev/` as a project's config. The server runs from the checkout, so the environment runs the current code. The dev tasks open the apps on the projects `dev` and `agency`, which your registry names. The tasks are atomic:

| Task | Does |
| --- | --- |
| `dev:bootstrap` | refuses without `dev/server.toml`; for each `omunculus.toml` of `dev/`, creates its workspace, copies into it the `workspace/` files of the packs it imports that it lacks, as the `pack` tool does, and seeds its local administrator while its store does not exist |
| `dev:serve` | runs the server on `dev/server.toml`, with the variables of `.env` (the keys the dev configs' logins name) in its environment and, while the dream team's environment is up (`packs/dream-team/environment/up`), `OMUNCULUS_DEPLOY` set to its sockets folder, which a project's `[execution] write` may name, `OMUNCULUS_HOMOLOGATION_KEY` and `OMUNCULUS_PRODUCTION_KEY` from its keys unless `.env` gives them, and `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL`, unless `.env` sets them, your `git config` name and email, which a project's `[execution] environment` may pass to its commands, so its builders commit as you |
| `dev:console` | opens the console on the `dev` project of a running server |
| `dev:mailbox` | opens the mailbox on the `dev` project of a running server |
| `dev:studio` | opens the studio on the `agency` project of a running server (`-- --project dev` for the other) |
| `dev:reset` | deletes the store and the workspace of each project config of `dev/` |
| `up` | `dev:bootstrap`, then `dev:serve` unless a server already answers |

While the dev server runs, `bin/omunculus --config dev/omunculus.toml <command>` goes to it through the socket.
