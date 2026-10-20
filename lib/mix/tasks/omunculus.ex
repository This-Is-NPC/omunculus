defmodule Mix.Tasks.Omunculus do
  @moduledoc """
  The `omunculus` binary: `omunculus [--config <path>] <name> [--key value]`
  dispatches the tool `<name>` through `Omunculus.CLI.main/1`, and
  `omunculus serve --config <server.toml>` starts the HTTP server.

  ## Dispatch

  `omunculus send` is the `send` tool, `omunculus inbox` the `inbox` tool:
  the same `{name, args, view}` in and `{ok, output, emit, chain}` out the
  model uses, with the trigger `cli`. Replacing the folder named `send`
  replaces the command. A name the catalog does not hold is a refusal.

  `--config <path>` is the only flag of the binary itself, and it comes
  first. Without it the file is `./omunculus.toml` in the working directory;
  `bin/omunculus` passes that path unless the first argument is already
  `--config` or `serve`, and makes a relative `--config` absolute against
  the caller's directory. The project root is the directory of that file,
  or its `[project] root` resolved against it; the store is its
  `[store] path`, resolved against it too. No environment variable
  chooses the file. A missing file is a refusal, except for a tool whose
  manifest sets `config = false`, as `preset`, which writes the file.

  After the name come `--key value` pairs, or one bare value, which goes to
  the first required key of the tool's parameters: `omunculus send "count
  to 5"` gives `message`. A second bare value, or a `--key` without a value,
  is a usage error. A key the parameters do not list is still passed on.
  Every value arrives as text; a tool that takes JSON decodes it.

  ## Output

  Stdout is the tool's `output` and nothing else; an empty one is a
  success with nothing to print. A refusal or a failure is one line on
  stderr, a reason without a sentence of its own printed as the Elixir
  term, and the exit status 1; success is 0, and there is no other. A
  command that opens runs returns once every run it opened, directly or
  through other runs, has finished, and fails with the errors of any of
  them, one per line.

  ## The project's lock

  A command takes the project's lock and first recovers what a process
  that stopped left: it closes the runs left open and makes due again the
  runs that never began. While a server holds the lock, the command goes
  to it over the project's local socket, runs there as the local user,
  under the project's `[access]`, and returns the same output. A project
  held by another direct command is refused as in use.

  ## Commands that are not tools

  `omunculus --config <project.toml> access bootstrap --issuer <issuer>
  --subject <subject>` seeds the first project administrator; only the
  owner of the config file may, and only while the project has no member.

  `omunculus serve --config <server.toml>` starts the HTTP server on the
  projects its registry lists, until it is stopped.
  """

  use Mix.Task

  @shortdoc "Dispatches a tool by name"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    Application.put_env(:omunculus, :package_tools, Application.app_dir(:omunculus, "priv/tools"))

    case argv do
      ["serve" | rest] -> Omunculus.Server.main(rest)
      _ -> Omunculus.CLI.main(argv)
    end
  end
end
