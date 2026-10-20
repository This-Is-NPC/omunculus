# How to run the server

**The question:** how do I serve a project so an HTTP client can reach it?

This page is enough on its own to serve one project on its local socket. Web users on a TCP listener, with tokens, are
in [the server](server.md#tcp-listener).

## Before you start

- A project whose `omunculus.toml` loads
  ([how to start a project](how-to-start-a-project.md)).
- `flock`, which the server and the command line take the project's lock
  with.
- `<checkout>` is a placeholder for the folder of the omunculus checkout.

## Steps

1. Give the project access roles. A served project needs an `[access]`
   table; append it to `omunculus.toml`:

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
   ```

2. Make yourself its first administrator. The local user is the issuer
   `local` with your numeric user id as subject.

   ```console
   $ <checkout>/bin/omunculus access bootstrap --issuer local --subject "$(id -u)"
   access bootstrapped
   ```

3. Write a server registry, `server.toml`, beside the project. `demo` is
   the project's id; paths resolve against the registry.

   ```toml
   [server]
   max_concurrent = 8
   max_queue = 64
   queue_timeout_ms = 30000
   max_connections = 64

   [projects.demo]
   config = "omunculus.toml"
   ```

4. Start the server. It prints nothing while it runs, and serves the
   project on a socket beside its store.

   ```console
   $ <checkout>/bin/omunculus serve --config server.toml
   ```

   In another terminal:

   ```console
   $ ls .omunculus
   store.sqlite3  store.sqlite3.omunculus.lock  store.sqlite3.omunculus.sock  store.sqlite3-shm  store.sqlite3-wal
   $ curl -s --unix-socket .omunculus/store.sqlite3.omunculus.sock http://localhost/v1/projects
   {"items":[{"id":"demo","socket":"/tmp/omu-howto/served/.omunculus/store.sqlite3.omunculus.sock"}]}
   ```

5. Use the command line as before: while the server holds the project, a
   command goes to it over the socket and returns once its runs finish.

   ```console
   $ <checkout>/bin/omunculus send "hello" --agent concierge
   $ curl -s --unix-socket .omunculus/store.sqlite3.omunculus.sock http://localhost/v1/projects/demo/conversations
   {"items":[{"id":"7005136b5446fd6c0dce25c45b9a50e5","created_at":"2026-10-13T17:14:55.565875Z","created_issuer":"local","created_subject":"1000"}]}
   ```

6. Stop the server with SIGTERM (`kill <pid>`, `<pid>` the placeholder of
   its process id); it stops its projects and removes the socket.

## What can go wrong

- A project without `[access]` cannot be bootstrapped, and the reason
  prints as an Elixir term
  ([defect 1](what-does-not-work.md#1-some-refusals-print-as-elixir-terms)):

  ```console
  $ <checkout>/bin/omunculus access bootstrap --issuer local --subject "$(id -u)"
  :access_disabled
  ```

- The socket's path must fit in 107 bytes, or the server does not start;
  keep the store's path short.
- A project held by a direct command that is still running is in use;
  start the server once the command has returned.

## Where to go next

- [The server](server.md): the `/v1` contract, the event stream and the
  TCP listener.
- [Clients](clients.md): what a client may rely on.
