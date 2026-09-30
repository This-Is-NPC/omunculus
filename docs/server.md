# HTTP server

The server is optional. Direct CLI commands open the project store themselves. The server keeps each registered project open, with its own SQLite file and run cycle. Start only one owner of a project at a time: CLI and server commands acquire a `flock` lock next to the SQLite file. The server requires Linux `flock` and a project `[access]` table.

Add access roles to a project config:

```toml
[access]
creator_role = "participant"
bootstrap_role = "admin"

[access.roles.admin]
scope = "project"
capabilities = ["project.manage_access", "project.manage_config", "conversation.create", "conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access", "conversation.manage"]

[access.roles.participant]
scope = "conversation"
capabilities = ["conversation.read", "conversation.send", "conversation.comment", "conversation.reply", "conversation.manage_access"]

[access.roles.reader]
scope = "conversation"
capabilities = ["conversation.read"]
```

The capabilities accepted by the config are `project.manage_access`, `project.manage_config`, `conversation.create`, `conversation.read`, `conversation.send`, `conversation.comment`, `conversation.reply`, `conversation.manage_access` and `conversation.manage`. A role grants only the capabilities it lists. Project roles apply to all conversations; conversation roles apply to one. A member can assign only capabilities they hold. The last bootstrap administrator cannot be removed.

Before starting the server, seed the first project administrator. For the local user, the principal is issuer `local` and the numeric user ID as subject, the same principal the direct CLI acts as:

```sh
bin/omunculus --config /path/to/project/omunculus.toml access bootstrap --issuer local --subject "$(id -u)"
```

For web users, use the subject of a token issued by your identity provider instead, for example `--issuer my-idp --subject alice`. The caller must own the project config file. Bootstrap works once while the project has no members. Make a server registry TOML:

```toml
[server]
max_concurrent = 8
max_queue = 64
queue_timeout_ms = 30000
max_connections = 64

[projects.demo]
config = "/path/to/project/omunculus.toml"
```

```sh
bin/omunculus serve --config /path/to/server.toml
```

Paths in the registry resolve relative to it. `max_concurrent`, `max_queue` and `queue_timeout_ms` bound runs across projects in addition to each project's `[execution]` limits. `max_connections` bounds simultaneous event streams.

## Local socket

Each project is served on a Unix socket next to its SQLite file, `<store path>.omunculus.sock`, with mode `0600`: only the user running the server can connect. Requests on it need no token and act as the local principal. Any HTTP client that can use a Unix socket works:

```sh
curl --unix-socket .omunculus/store.sqlite3.omunculus.sock http://localhost/v1/projects/demo/conversations
```

The direct CLI uses the socket too: while the server owns the project, `bin/omunculus <command>` posts its command line to `POST /v1/cli`, which only the socket serves, and waits for the runs that command opened.

The socket path must fit in 107 bytes; a longer one keeps the server from starting. The server removes the socket when it stops, and a socket left by a server that crashed is replaced by the next one.

## TCP listener

To serve web apps, add `host` and `port` to `[server]` together with an `[auth]` table. One comes only with the other.

```toml
[server]
host = "127.0.0.1"
port = 4000
# limits as above

[auth]
issuer = "my-idp"
audience = "omunculus"
algorithm = "RS256"
public_key = "./jwt-public.pem"
```

The public key must be a PEM key; `RS256` and `ES256` are accepted. Tokens must be signed and contain matching `iss` and `aud`, a nonempty `sub`, a future `exp`, and an optional valid `nbf`. The server does not issue tokens.

The server publishes an OpenAPI 3.1 document at `GET /openapi.json`, without authentication. It is generated from the same declarations that register the Plug routes, so the list of paths and HTTP methods follows the running server. Request and response schemas are defined in `Omunculus.Server.OpenAPI`. A web app can import this URL into an OpenAPI client generator or documentation viewer. The document itself is JSON; the server does not bundle a browser documentation UI.

## Contract

On the TCP listener, send `Authorization: Bearer <JWT>` on every request. Use `/v1/projects/{project}` as the base path. Conversation creation and tool commands require an `Idempotency-Key` header of 1 to 128 bytes. Repeating the same operation with the same key returns its original result; using that key for a different operation returns `409`. Conversation creation returns `201`; a successful tool command returns `202` and a cursor, while its runs proceed asynchronously.

| Method and path | Purpose |
| --- | --- |
| `GET /v1/identity` | Return the token principal. |
| `GET, POST /conversations` | List visible conversations or create one. |
| `GET /conversations/{id}` | Read one visible conversation. |
| `GET /conversations/{id}/snapshot` | Read works, runs, prompts, requests and inbox at one event cursor. |
| `GET /conversations/{id}/{works,runs,prompts,requests,inbox}` | Read one resource list. |
| `GET /conversations/{id}/events?after={cursor}` | Read up to 500 later events in sequence order. |
| `GET /conversations/{id}/stream?after={cursor}` | Open a WebSocket of later events; see [Event stream](#event-stream). |
| `POST /conversations/{id}/messages` | Send `{"message":"text"}` with optional `work_id`. |
| `POST /conversations/{id}/requests/{request_id}/reply` | Send `{"option":"name","body":"text"}`. |
| `POST /conversations/{id}/comments` | Send `{"body":"text"}` and exactly one of `work_id`, `request_id` or `inbox_id`. |
| `POST /conversations/{id}/inbox/{inbox_id}/read` | Mark an inbox item read. |
| `POST /members`, `DELETE /members/{issuer}/{subject}` | Assign or revoke a project role. |
| `POST /conversations/{id}/members`, `DELETE /conversations/{id}/members/{issuer}/{subject}` | Assign or revoke a conversation role. |

Membership `POST` bodies are `{"issuer":"my-idp","subject":"bob","role":"reader"}`. Create a conversation, then send a message with an idempotency key. Fetch its snapshot and resume with `/events?after=<snapshot.cursor>` or `/stream?after=<snapshot.cursor>`. Each event includes version `v`, `cursor`, `project`, `type`, `at`, `actor`, `origin`, resource IDs and `body`. A caller without access gets `404` for conversation resources.

## Event stream

`GET /conversations/{id}/stream` upgrades to a WebSocket, authenticated like any other request: the local principal on the socket, the `Authorization` header on TCP. A request without the WebSocket upgrade headers gets `400`. The stream is read-only; commands go through the `POST` routes.

Each frame is a JSON text frame. The first frames are the events after `after` (all of them without it), then each event as soon as it is committed, with its cursor in `cursor`. Partial model text arrives as `{"v":1,"type":"run.delta","project","run_id","work_id","text"}` without a cursor; it is not stored, so a resumed stream does not repeat it, and the recorded `model` event holds the whole reply. The server pings every 15 seconds and reads again, so a revoked membership closes the stream even while the conversation is idle.

| Close code | Reason |
| --- | --- |
| `1003 unsupported` | The client sent a data frame. |
| `1008 forbidden` | The caller lost read access to the conversation. |
| `1011 internal_error` | The server could not read the events. |
| `1013 too_many_streams` | `max_connections` streams are already open. |

An older store without conversation columns is rejected and must be recreated. The server closes runs left open by an interrupted process and applies the existing retry policy to their work. HTTP requests do not wait for a run to finish.
