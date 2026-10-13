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
| `GET /v1/projects` | List the projects you see: over HTTP, those whose conversations you may read or where you are a member of one; on a local socket, every project of the registry with its `socket`. |
| `GET /agents/{agent}/image` | Read an agent's `image`, with its media type, if the project is visible to you; `404` for an agent without one. |
| `GET, POST /conversations` | List visible conversations or create one. |
| `GET /works?state={state}` | List the works of every conversation you may read, oldest first, each with its `conversation_id`; `state` (`open`, `waiting`, `done` or `cancelled`) keeps those in it alone, and any other value is `400`. |
| `GET /stream?after={cursor}` | Open a WebSocket of the later events of every conversation you may read; see [Event stream](#event-stream). |
| `GET /conversations/{id}` | Read one visible conversation. |
| `GET /conversations/{id}/snapshot` | Read works (each with the `workflow` it goes through and its `stage`), runs, prompts, requests and inbox at one event cursor. |
| `GET /conversations/{id}/{works,runs,prompts,requests,inbox}` | Read one resource list. |
| `GET /conversations/{id}/events?after={cursor}` | Read up to 500 later events in sequence order. |
| `GET /conversations/{id}/stream?after={cursor}` | Open a WebSocket of later events; see [Event stream](#event-stream). |
| `POST /conversations/{id}/messages` | Send `{"message":"text","agent":"name"}` to an agent of depth 0, or `{"message":"text","work_id":"id"}` to a work; one of the two, never both. A message the store refuses (an agent not at depth 0) is `422 message_refused`. Either may carry `"attachments":[{"name":"notes.txt","media_type":"text/plain","data":"<base64>"}]` when the project's `[store] attachments` is set; the server keeps each file and the message's `prompt` event describes it as `{name, media_type, bytes, sha256}`. A file past `[store] attachment_bytes`, or attachments without that directory, is `422 attachment_refused`. |
| `GET /conversations/{id}/attachments/{sha256}` | Read a file attached in the conversation, by a message or an agent's `attach`, with its media type and name. |
| `POST /conversations/{id}/requests/{request_id}/reply` | Send `{"body":"text"}`, optionally with `"option":"name"` to execute that option's calls, and recursive `"parts":{"name":{"body":"text","option":"choice"}}` for linked origins. |
| `POST /conversations/{id}/comments` | Send `{"body":"text"}` and exactly one of `work_id`, `request_id` or `inbox_id`. |
| `POST /conversations/{id}/inbox/{inbox_id}/read` | Mark an inbox item read. |
| `POST /members`, `DELETE /members/{issuer}/{subject}` | Assign or revoke a project role. |
| `POST /conversations/{id}/members`, `DELETE /conversations/{id}/members/{issuer}/{subject}` | Assign or revoke a conversation role. |

Membership `POST` bodies are `{"issuer":"my-idp","subject":"bob","role":"reader"}`. Create a conversation, then send a message with an idempotency key. Fetch its snapshot and resume with `/events?after=<snapshot.cursor>` or `/stream?after=<snapshot.cursor>`. Each event includes version `v`, `cursor`, `project`, `conversation_id`, `type`, `at`, `actor`, `origin`, resource IDs and `body`. A caller without access gets `404` for conversation resources.

Request resources expose `requester` and `arbiter` as participant objects:
`{"kind":"agent","agent":"name"}` or
`{"kind":"human","issuer":"issuer","subject":"subject"}`. The former
`agent` column and `waiting_agent` / `waiting_human` statuses are absent.
Statuses are `pending`, `escalated` and `closed`; only pending requests can be
answered directly. `run_id` and `work_id` may be null. `origins` recursively
maps part names to their canonical requests, including the original `reason`,
`workflow`, `stage` and options. Replies authorize each named effect for its
original target and the actual authenticated answerer. Omit `option` for text;
explicit null or empty values return `400`. A person escalates through
`/requests/escalate`, below.

## Event stream

`GET /conversations/{id}/stream` upgrades to a WebSocket, authenticated like any other request: the local principal on the socket, the `Authorization` header on TCP. A request without the WebSocket upgrade headers gets `400`. The stream is read-only; commands go through the `POST` routes.

Each frame is a JSON text frame. The first frames are the events after `after` (all of them without it), then each event as soon as it is committed, with its cursor in `cursor`. Partial model text arrives as `{"v":1,"type":"run.delta","project","conversation_id","run_id","work_id","text"}` without a cursor; it is not stored, so a resumed stream does not repeat it, and the recorded `model` event holds the whole reply. The server pings every 15 seconds and reads again, so a revoked membership closes the stream even while the conversation is idle.

`GET /stream` is the same for the whole project: its frames are the events and partial replies of every conversation you may read, in sequence order, each naming its `conversation_id`, and its cursor is any event's. Each read decides again which conversations those are, so a conversation created or shared with you joins the stream, and one whose membership is revoked leaves it without closing it.

| Close code | Reason |
| --- | --- |
| `1003 unsupported` | The client sent a data frame. |
| `1008 forbidden` | The caller lost read access to the conversation (a conversation's stream only). |
| `1011 internal_error` | The server could not read the events. |
| `1013 too_many_streams` | `max_connections` streams are already open. |

An older store without conversation or participant request columns, escalation
links or the current request status constraint is rejected and must be
explicitly recreated. The server closes runs left open by an interrupted process and applies the existing retry policy to their work; then a request still pending at an agent whose last run for it has closed, its follow-up lost with the process, goes on along its route as an unanswered one does. HTTP requests do not wait for a run to finish.

## Human request commands

`POST /v1/projects/:project_id/conversations/:conversation_id/requests` creates
an authenticated human's question or decision using `ask`. Its JSON body is
`{question, options?, to?}`; options is an array of named answers without effect
calls. It requires conversation send access. `POST` at the same path followed
by `/escalate` takes `{reason, origins, to?}`, where origins maps distinct part
names to pending received request IDs. It requires conversation reply access;
every origin must belong to the URL's conversation and its recorded arbiter
must be the caller. Optional `to` names a configured logical route.

Both commands require `Idempotency-Key`, return 202 with the accepted command
receipt, and reuse the shared CLI/model tools, store actions and reply path.
Replaying the same key and body returns its receipt; changing the body conflicts.
The verified principal supplies authorship. Unknown body fields and malformed
required fields return 400; hidden conversations or cross-conversation targets
return 404; a request/escalation domain refusal returns 422. Human requests
have no requester run. Configured agent receivers open runs, and human
receivers get the request without a synthetic run. Snapshot request reads retain
the original identities, questions and linked origins.
