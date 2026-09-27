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

Before starting the server, seed the first project administrator with the subject of a token issued by your identity provider:

```sh
bin/omunculus --config /path/to/project/omunculus.toml access bootstrap --issuer my-idp --subject alice
```

The caller must own the project config file. Bootstrap works once while the project has no members. Make a server registry TOML:

```toml
[server]
host = "127.0.0.1"
port = 4000
max_concurrent = 8
max_queue = 64
queue_timeout_ms = 30000
max_connections = 64

[auth]
issuer = "my-idp"
audience = "omunculus"
algorithm = "RS256"
public_key = "./jwt-public.pem"

[projects.demo]
config = "/path/to/project/omunculus.toml"
```

Paths in the registry resolve relative to it. The public key must be a PEM key; `RS256` and `ES256` are accepted. Tokens must be signed and contain matching `iss` and `aud`, a nonempty `sub`, a future `exp`, and an optional valid `nbf`. The server does not issue tokens. `max_concurrent`, `max_queue` and `queue_timeout_ms` bound runs across projects in addition to each project's `[execution]` limits. `max_connections` bounds simultaneous event streams.

```sh
bin/omunculus serve --config /path/to/server.toml
```

## Web app contract

Send `Authorization: Bearer <JWT>` on every request. Use `/v1/projects/{project}` as the base path. Conversation creation and tool commands require an `Idempotency-Key` header of 1 to 128 bytes. Repeating the same operation with the same key returns its original result; using that key for a different operation returns `409`. Conversation creation returns `201`; a successful tool command returns `202` and a cursor, while its runs proceed asynchronously.

| Method and path | Purpose |
| --- | --- |
| `GET /v1/identity` | Return the token principal. |
| `GET, POST /conversations` | List visible conversations or create one. |
| `GET /conversations/{id}` | Read one visible conversation. |
| `GET /conversations/{id}/snapshot` | Read works, runs, prompts, requests and inbox at one event cursor. |
| `GET /conversations/{id}/{works,runs,prompts,requests,inbox}` | Read one resource list. |
| `GET /conversations/{id}/events?after={cursor}` | Read up to 500 later events in sequence order. |
| `GET /conversations/{id}/stream?after={cursor}` | Stream later events as SSE; each event has its cursor as SSE `id`. |
| `POST /conversations/{id}/messages` | Send `{"message":"text"}` with optional `work_id`. |
| `POST /conversations/{id}/requests/{request_id}/reply` | Send `{"option":"name","body":"text"}`. |
| `POST /conversations/{id}/comments` | Send `{"body":"text"}` and exactly one of `work_id`, `request_id` or `inbox_id`. |
| `POST /conversations/{id}/inbox/{inbox_id}/read` | Mark an inbox item read. |
| `POST /members`, `DELETE /members/{issuer}/{subject}` | Assign or revoke a project role. |
| `POST /conversations/{id}/members`, `DELETE /conversations/{id}/members/{issuer}/{subject}` | Assign or revoke a conversation role. |

Membership `POST` bodies are `{"issuer":"my-idp","subject":"bob","role":"reader"}`. Create a conversation, then send a message with an idempotency key. Fetch its snapshot and resume with `/events?after=<snapshot.cursor>` or `/stream?after=<snapshot.cursor>`. Each event includes version `v`, `cursor`, `project`, `type`, `at`, `actor`, `origin`, resource IDs and `body`. Access is checked again during streaming, so revocation closes the stream. A caller without access gets `404` for conversation resources.

An older store without conversation columns is rejected and must be recreated. The server closes runs left open by an interrupted process and applies the existing retry policy to their work. HTTP requests do not wait for a run to finish.
