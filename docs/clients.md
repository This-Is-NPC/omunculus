# Clients

A client is any program that talks to the [server](server.md): a GUI, a TUI,
a web app, a script. The server's HTTP contract is the only thing a client
and the core share. It is versioned under `/v1` and described by the
OpenAPI document the server publishes at `/openapi.json`.

## The boundary

- A client reaches a project only through that contract: on the project's
  local socket, as the local user, or on the TCP listener with a signed JWT.
  It never opens the store, reads the TOML or calls code under `lib/` or
  `priv/`.
- The core never names a client. No endpoint, field or behaviour exists for
  one app; what a client needs is added to the contract for every client.
- `mise run validate:boundaries`, part of `mise run pre-commit`, refuses a
  tracked line of `apps/` that names `lib/`, `priv/`, `omunculus.toml` or
  the store, a line of `lib/` or `priv/` that names `apps/`, a line of
  `apps/kit/ui` that imports the client, an import under `apps/` whose path
  leaves its folder, and any link under `apps/` but an app's `kit` link. Since
  Quickshell imports only from within the folder an app runs, an app reaches
  no other app and the kit reaches no app.
- Apps call each other only through Quickshell IPC
  (`quickshell ipc --path apps/<app> call …`), never by importing.
- A launcher may find the first socket with `mix omunculus.socket
  <server.toml> [<id>]`; from there, `GET /v1/projects` lists every project
  of the registry with its socket.

## The apps in this repository

`apps/` holds the clients that come with Omunculus, each a folder that
`apps/kit/run <app> --config <server.toml> [--project <id>]` opens on a
project, given as `OMUNCULUS_PROJECT` and its local socket as
`OMUNCULUS_SOCKET`:

| App | Is |
| --- | --- |
| [`apps/console`](console.md) | the window on one project: its conversations, each as threads of its agents' runs, and the orchestration map of its agents, works and requests; and a board of the works of every project of the registry, by state |
| [`apps/mailbox`](mailbox.md) | a mailbox over every project: a thread is a conversation with one agent of depth 0, and its requests to you are answered there |
| [`apps/studio`](studio.md) | the settings of a project: its flowchart on a canvas, then one item of the config at a time |

All are QML on Quickshell and share `apps/kit`:

- `apps/kit/ui`: the theme and the controls more than one app uses, among
  them `FlowCanvas`, a canvas that moves, zooms and pinches, and its
  `ZoomControl`, and `TabRail`, an app's pages as a carousel down the left
  edge, with `PageBar`, the commands of the page on screen beside it and the
  app's readout, which the app gives it, and `FilePicker` and `FileChip`,
  the files a message carries and a file attached in a conversation. It
  knows nothing of Omunculus.
- `apps/kit/client`: `Http`, which makes each request to a socket through
  `curl` or saves its answer into a file, posts a message with files through
  `post-with-files` and saves and opens an attached file through
  `open-attachment`, the scripts beside it, `AgentImages`, which keeps the
  agents' images in Quickshell's cache, and `Requests.js`, the helpers
  that read a request's status and participants and build a reply.

Each app reaches the kit through a `kit` link to `apps/kit/`, since
Quickshell imports only from within the folder it runs. The kit imports no
app, and a control moves into it only once two apps use it.
