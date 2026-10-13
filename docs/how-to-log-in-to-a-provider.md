# How to log in to a provider

**The question:** how do I put a project's agents on a real model, with my
key?

This page is enough on its own for a provider whose API key you have. Which
APIs a model can speak, and the other kinds of login, are in
[the TOML](config.md#models-and-auth).

## Before you start

- A project whose `omunculus.toml` loads
  ([how to start a project](how-to-start-a-project.md)).
- An API key of the provider. The steps use Anthropic; any provider of
  [the compatible providers](config.md#compatible-providers) works the
  same way with its own `api`, `url` and `model`.
- `<checkout>` is a placeholder for the folder of the omunculus checkout.

## Steps

1. Declare the login and the model in `omunculus.toml`. An empty `key`
   falls through to a key stored with `login`; `key = "$ANTHROPIC_API_KEY"`
   would read it from the environment instead, and a stored login is then
   not needed.

   ```toml
   [auth]
   store = ".omunculus/auth.json"

   [auth.anthropic]
   kind = "api_key"
   key = ""

   [models.claude]
   provider = "anthropic"
   api = "anthropic-messages"
   url = "https://api.anthropic.com/v1"
   model = "claude-sonnet-4-5"
   timeout_ms = 120000
   body = { max_tokens = 32000 }
   ```

   An HTTP model needs `timeout_ms`, and an `anthropic-messages` model
   needs `body = { max_tokens = n }`; without them the file does not load.

2. Store the key. `--key` gives it on the command line; without it,
   `login` asks for it on stdin after `api key: `.

   ```console
   $ <checkout>/bin/omunculus login --provider anthropic --key <key>
   logged in to anthropic
   ```

   `<key>` is a placeholder for your key. The file `[auth] store` names is
   written with mode 0600:

   ```console
   $ ls -l .omunculus/auth.json
   -rw------- 1 howl howl 55 Oct 13 14:15 .omunculus/auth.json
   ```

3. Try the model before any agent runs on it. `model_test` sends one short
   prompt without tools and prints `{"reply", "ms"}`. Against the `fake`
   model, which needs no key:

   ```console
   $ <checkout>/bin/omunculus model_test fake
   {"reply":"fake model: This is a connection test. Reply with the single word: ok","ms":0}
   ```

   Against `claude` it prints the provider's reply the same way. That run
   is not shown here: the examples of these pages use no real key.

4. Put the agents on the model: set `model = "claude"` in each
   `[agents.<name>]` table, and in `models` of each `[[packs]]` entry for
   a pack's roles.

## What can go wrong

- A provider the TOML does not declare:

  ```console
  $ <checkout>/bin/omunculus login --provider nobody --key x
  unknown auth provider: nobody
  ```

- No key stored and an empty `key`: the request goes without one and the
  provider refuses it; the reason prints as an Elixir term
  ([defect 1](what-does-not-work.md#1-some-refusals-print-as-elixir-terms)):

  ```console
  $ <checkout>/bin/omunculus model_test claude
  {:anthropic, {:http, 401, %{"error" => %{"message" => "x-api-key header is required", "type" => "authentication_error"}, "request_id" => "req_011CfzcY3HwwgQE47DrSHTwM", "type" => "error"}}}
  ```

- `logout` removes the stored key and leaves the TOML as it is:

  ```console
  $ <checkout>/bin/omunculus logout --provider anthropic
  logged out of anthropic
  ```

## Where to go next

- [The TOML](config.md#models-and-auth): OAuth logins, `$VAR` and `!cmd`
  keys, keys kept by omapass, and the model keys `stream`, `retries` and
  `code_mode`.
- [How to import a pack](how-to-import-a-pack.md), whose roles take a model
  each.
