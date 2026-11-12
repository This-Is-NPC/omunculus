defmodule Omunculus.CLI do
  @moduledoc """
  The command-line adapter: `omunculus <name> [args]` resolves
  `--config <path>` (default `./omunculus.toml` in the given cwd), reads
  the rest as the arguments of the tool `<name>` and runs it through
  `Operations`, as the local principal with `trigger: "cli"`. The
  project root is the config file's directory, or `[project] root`
  relative to it. Tools with `config = false` run without opening the
  store. A command returns once every run it opened, transitively, has
  finished; the error of any of them fails the command, several one per
  line. A tool command prints its output, then what the runs it caused
  gave the person (`Operations.reply/2`). When a server owns the project,
  the command goes to it over the project's local socket and is answered
  the same way. Taking the
  project's lock itself, the command first recovers what a process that
  stopped left (`Run.recover/1`), and returns once those runs have
  finished too.
  """

  alias Omunculus.{Config, Cycle, Errors, Harness, Operations, Project, Run}
  alias Omunculus.Server.Socket
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, term}
  def run(argv, cwd) do
    with {:ok, config_path, rest} <- split_config(argv, cwd) do
      case rest do
        [] ->
          {:error, :no_tool}

        ["access", "bootstrap", "--issuer", issuer, "--subject", subject] ->
          with {:ok, config} <- Config.load(config_path),
               do: execute(config, {:bootstrap, %{issuer: issuer, subject: subject}})

        [name | args] ->
          case Map.get(Catalog.unconfigured(), name) do
            %Manifest{config: false} = manifest ->
              project = %Project{
                dir: Path.dirname(config_path),
                conn: nil,
                config_path: config_path
              }

              with {:ok, args} <- build_args(args, manifest),
                   do: Operations.command(project, name, args, false)

            _other ->
              with {:ok, config} <- Config.load(config_path),
                   {:ok, manifest} <- Harness.manifest(config, name),
                   {:ok, args} <- build_args(args, manifest),
                   do: execute(config, {:tool, name, args})
          end
      end
    end
  end

  @spec main([String.t()]) :: :ok
  def main(argv) do
    case run(argv, File.cwd!()) do
      {:ok, output} ->
        if output != "", do: IO.puts(output)
        :ok

      {:error, reason} ->
        IO.puts(:stderr, message(reason))
        System.halt(1)
    end
  end

  @doc "The line an error prints as, with the command that resolves it when there is one."
  @spec message(term) :: String.t()
  def message({:forwarded, message}), do: message

  def message({:config, :missing, _path} = reason),
    do: Errors.format(reason) <> "; run `omunculus preset <name> --from <dir>`"

  def message({:auth, :not_logged_in, id} = reason),
    do: Errors.format(reason) <> "; run `omunculus login --provider #{id}`"

  def message({:prompt, {:agent_required, _depth, _names}} = reason),
    do: Errors.format(reason) <> "; name one with --agent"

  def message(:no_tool), do: "no command given; name a tool, as `omunculus send \"hello\"`"
  def message({:missing_value, key}), do: "--#{key} needs a value"
  def message({:positional, value}), do: "unexpected argument #{value}"
  def message(reason), do: Errors.format(reason)

  defp split_config(["--config"], _cwd), do: {:error, {:missing_value, "config"}}

  defp split_config(["--config", path | rest], cwd),
    do: {:ok, Path.expand(path, cwd), rest}

  defp split_config(argv, cwd),
    do: {:ok, Path.expand("omunculus.toml", cwd), argv}

  defp execute(config, command) do
    case Project.open(config, lock: true) do
      {:ok, project} ->
        try do
          with {:ok, started} <-
                 Cycle.run(project, nil, fn project ->
                   with :ok <- Run.recover(project), do: perform(project, command)
                 end),
               do: {:ok, Operations.reply(project, started)}
        after
          Project.close(project)
        end

      {:error, :project_in_use} ->
        forward(config, command)

      error ->
        error
    end
  end

  defp perform(project, {:tool, name, args}), do: Operations.start(project, name, args)

  defp perform(project, {:bootstrap, target}) do
    with :ok <- Operations.bootstrap_access(project, target),
         do: {:ok, {"access bootstrapped", []}}
  end

  # A project held without a socket, by another direct command, stays in use.
  defp forward(config, command) do
    {path, body} =
      case command do
        {:tool, name, args} -> {"/v1/call", %{name: name, args: args}}
        {:bootstrap, target} -> {"/v1/access/bootstrap", target}
      end

    case Req.post("http://localhost" <> path,
           unix_socket: Socket.path(config.store.path),
           json: body,
           receive_timeout: :infinity,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"output" => output}}} -> {:ok, output}
      {:ok, %{status: 200, body: %{"status" => "bootstrapped"}}} -> {:ok, "access bootstrapped"}
      {:ok, %{status: 422, body: %{"message" => message}}} -> {:error, {:forwarded, message}}
      {:ok, %{status: status}} -> {:error, {:forwarded, "server replied #{status}"}}
      {:error, _unreachable} -> {:error, :project_in_use}
    end
  end

  defp build_args(rest, manifest) do
    positional_key =
      case Map.get(manifest.parameters, "required") do
        [key | _] -> key
        _ -> nil
      end

    parse_args(rest, %{}, positional_key, false)
  end

  defp parse_args([], acc, _positional_key, _used), do: {:ok, acc}

  defp parse_args(["--" <> key, value | rest], acc, positional_key, used),
    do: parse_args(rest, Map.put(acc, key, value), positional_key, used)

  defp parse_args(["--" <> key], _acc, _positional_key, _used),
    do: {:error, {:missing_value, key}}

  defp parse_args([value | rest], acc, positional_key, false) when not is_nil(positional_key),
    do: parse_args(rest, Map.put(acc, positional_key, value), positional_key, true)

  defp parse_args([value | _rest], _acc, _positional_key, _used),
    do: {:error, {:positional, value}}
end
