defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` resolves
  `--config <path>` (default `./omunculus.toml` in the given cwd) and
  calls the same contract the model uses, with `trigger: "cli"`. The
  project root is the config file's directory, or `[project] root`
  relative to it. Tools with `config = false` run without opening the
  store. Configured calls hand their events to `Harness.follow_up/2`,
  which opens runs whose model comes from `agents.<x>.model`, and
  returns once every run the call opened, transitively, has finished;
  the error of any of them fails the command, several one per line.
  When a server owns the project, the command line goes to it over the
  project's local socket and is answered the same way.
  """

  alias Omunculus.{Config, Harness, Operations, Project}
  alias Omunculus.Server.Socket
  alias Omunculus.Store.Access
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, term}
  def run(argv, cwd) do
    with {:ok, config_path, rest} <- split_config(argv, cwd) do
      case rest do
        [] ->
          {:error, :no_tool}

        [name | args] ->
          case Map.get(Catalog.unconfigured(), name) do
            %Manifest{config: false} = manifest ->
              project = %Project{
                dir: Path.dirname(config_path),
                conn: nil,
                config_path: config_path
              }

              run_tool(manifest, name, args, project, false)

            _other ->
              with {:ok, config} <- Config.load(config_path), do: open(config, rest)
          end
      end
    end
  end

  @doc """
  Runs a command line, without `--config`, against a project already
  open, as the local principal.
  """
  @spec in_project(Project.t(), [String.t()]) :: {:ok, String.t()} | {:error, term}
  def in_project(project, ["access", "bootstrap", "--issuer", issuer, "--subject", subject]) do
    with :ok <- owner_of_config(project.config_path),
         :ok <- Access.bootstrap(project, %{issuer: issuer, subject: subject}) do
      {:ok, "access bootstrapped"}
    end
  end

  def in_project(project, [name | args]) do
    with {:ok, manifest} <- Harness.manifest(project, name) do
      run_tool(manifest, name, args, project, true)
    end
  end

  def in_project(_project, []), do: {:error, :no_tool}

  @spec main([String.t()]) :: :ok
  def main(argv) do
    case run(argv, File.cwd!()) do
      {:ok, output} ->
        if output != "", do: IO.puts(output)
        :ok

      {:error, reason} ->
        IO.puts(:stderr, format_error(reason))
        System.halt(1)
    end
  end

  @spec format_error(term) :: String.t()
  def format_error({:config, :missing, path}) do
    "no config at #{path}; run `omunculus preset <name> --from <dir>`"
  end

  def format_error({:execution, :missing, keys}) do
    "omunculus.toml is missing [execution]; required keys: #{Enum.join(keys, ", ")}"
  end

  def format_error({:execution, {:unknown_resource, name}}) do
    "omunculus.toml [execution] resources includes unknown name #{name}"
  end

  def format_error({:models, :missing}) do
    "omunculus.toml is missing [models]"
  end

  def format_error({:store, :missing}) do
    "omunculus.toml is missing [store]"
  end

  def format_error({:policy, {:invalid, :max_retries}}) do
    "omunculus.toml [policy] max_retries is required, a non-negative integer"
  end

  def format_error({:execution, {:sandbox, :missing}}) do
    "omunculus.toml is missing [execution.sandbox]"
  end

  def format_error({:agent, name, {:invalid, :model}}) do
    "omunculus.toml agent #{name} is missing model"
  end

  def format_error({:auth, :not_logged_in, id}) do
    "not logged in to #{id}; run `omunculus login --provider #{id}`"
  end

  def format_error({:overrides, tool, {:not_chainable, name}}) do
    "overrides.#{tool}.chains names #{name}, which the #{tool} manifest does not chain"
  end

  def format_error({:overrides, tool, {:invalid, :then}}) do
    "overrides of #{tool} leave a then outside its chains or with end not last"
  end

  def format_error({:overrides, tool, {:unknown_schema, variant}}) do
    "overrides.#{tool}.schema names #{variant}, which the #{tool} manifest does not declare"
  end

  def format_error(:no_runs), do: "no runs"
  def format_error(:project_in_use), do: "project is in use by another Omunculus process"

  def format_error(:store_requires_recreation),
    do: "store schema predates conversations; recreate the store"

  def format_error(:not_project_owner),
    do: "only the owner of the project config may bootstrap access"

  def format_error({:unknown_run, id}), do: "unknown run #{id}"
  def format_error(:no_assembled), do: "no assembled prompt"
  def format_error({:assemble, :missing}), do: "omunculus.toml is missing assemble"
  def format_error({:assemble, :empty}), do: "assemble returned an empty prompt"

  def format_error({:runs, reasons}), do: Enum.map_join(reasons, "\n", &format_error/1)
  def format_error({:forwarded, message}), do: message

  def format_error(reason), do: inspect(reason)

  defp split_config(["--config"], _cwd), do: {:error, {:missing_value, "config"}}

  defp split_config(["--config", path | rest], cwd),
    do: {:ok, Path.expand(path, cwd), rest}

  defp split_config(argv, cwd),
    do: {:ok, Path.expand("omunculus.toml", cwd), argv}

  defp open(config, argv) do
    case Project.open(config, lock: true) do
      {:ok, project} ->
        try do
          in_project(project, argv)
        after
          Project.close(project)
        end

      {:error, :project_in_use} ->
        forward(config, argv)

      error ->
        error
    end
  end

  # A project held without a socket, by another direct command, stays in use.
  defp forward(config, argv) do
    case Req.post("http://localhost/v1/cli",
           unix_socket: Socket.path(config.store.path),
           json: %{argv: argv},
           receive_timeout: :infinity,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"output" => output}}} -> {:ok, output}
      {:ok, %{status: 422, body: %{"message" => message}}} -> {:error, {:forwarded, message}}
      {:ok, %{status: status}} -> {:error, {:forwarded, "server replied #{status}"}}
      {:error, _unreachable} -> {:error, :project_in_use}
    end
  end

  defp owner_of_config(path) do
    if File.stat!(path).uid == File.stat!("/proc/self").uid,
      do: :ok,
      else: {:error, :not_project_owner}
  end

  defp run_tool(manifest, name, rest, project, follow_up?) do
    with {:ok, args} <- build_args(rest, manifest),
         {:ok, out, _events} <- Operations.call(project, name, args, %{}, follow_up?) do
      if out.ok, do: {:ok, out.output}, else: {:error, {:tool_failed, out.output}}
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
