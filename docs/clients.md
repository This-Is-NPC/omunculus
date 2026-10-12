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
  the store, a line of `lib/` or `priv/` that names `apps/`, and a line of
  `apps/kit` that imports an app or, in `ui`, the client.
- A launcher may find the first socket with `mix omunculus.socket
  <server.toml> [<id>]`; from there, `GET /v1/projects` lists every project
  of the registry with its socket.

## The apps in this repository

`apps/` holds the clients that come with Omunculus, each a folder that runs
on its own with a `run` launcher:

| App | Is |
| --- | --- |
| `apps/console` | the window on one project: its conversations, each as threads of its agents' runs, and the orchestration map of its agents, works and requests |
| `apps/mailbox` | a mailbox over every project: a thread is a conversation with one agent of depth 0, and its requests to you are answered there |

Both are QML on Quickshell and share `apps/kit`:

- `apps/kit/ui`: the theme and the controls more than one app uses. It knows
  nothing of Omunculus.
- `apps/kit/client`: `Http`, which makes each request to a socket through
  `curl`, and `Requests.js`, the helpers that read a request's status and
  participants and build a reply.

Each app reaches the kit through a `kit` link to `apps/kit/`, since
Quickshell imports only from within the folder it runs. The kit imports no
app, and a control moves into it only once two apps use it.
