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
- A launcher may find a project's socket with `mix omunculus.socket
  <server.toml> [<id>]`, where the id may be left out while the registry
  holds one project; from there, `GET /v1/projects` lists every project
  of the registry with its socket.

## The setup, read through `/v1/cli`

A client reads a project's setup by running the core's tools over
`POST /v1/cli` on the project's local socket ([the command line](cli.md)).
Two of them print a whole form for a client:

- `config --whole true` prints the setup as one JSON object: its `root`,
  `agents` (name, depth, model, `workflow_only`, the `granted`,
  `negotiable`, `human` and `deny` lists of its own layer, its text and
  the SHA-256 of its `image`, or null), `models` (name, `api`,
  `provider`, `model`, and nothing else of their tables), `workspaces`
  (name, root), the default `workspace` and `workflows` with their steps.
  For an editor it adds `document`: the `agents`, `models`, `workflows`,
  `workspaces`, `auth` providers and tool `secrets` by name and the
  `policy` and `access` tables, as the file writes them, but for a
  provider's literal `key`, which stays in the file; `literal_keys` names
  the providers that have one. It adds `revision`, the SHA-256 of the
  file's bytes, which `configure` takes back, and `names`, what a ceiling
  list may hold: the model tools, their groups and the sandbox resources.
- `overview --whole true` prints the project as it runs in each place a
  work can run. `places` holds each workspace, and the project root while
  no workspace is the default; a place has its `root`, whether it is the
  `default` and whether it lies `outside` the project, its own ceiling
  lists (`layer`), what it overlays (`changes`) and its `depths`. A depth
  has the `workflows` a work there may go through, each with its `name`,
  whether it is `required` there and its `stages` (name, `deny`, agent);
  whether the place `changed` them; and the `agents` a work goes to
  without a stage, an `idle` one being workflow-only. An agent has its
  `model` (name, id, api, `body`, whether the place `changed` it), the
  `key` of its provider (the provider and where its value comes from:
  `$VAR`, `omapass · <account>`, `command`, `stored login` or `in the
  file`, never the value), the names its layer lists, each with its
  `state` under the ceiling there (`have`, `askable`, `sealed`,
  `blocked`), a group's `members` and the `secrets` the config binds to
  it, the names its layer denies (`deny`) and, apart, its `skills`, each
  with its `description`, `state` and the tools its `allowed-tools` names
  (`uses`). `unused_workflows` are those no place runs.

The config tool loads the TOML in the harness's process; the sandbox hides
the file from external tools.
