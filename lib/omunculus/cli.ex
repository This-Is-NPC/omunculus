defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` resolves
  `--config <path>` (default `./omunculus.toml` in the given cwd) and
  calls the same contract the model uses, with `trigger: "cli"`. The
  project root is the config file's directory, or `[project] root`
  relative to it. Tools with `config = false` run without opening the
  store. Configured calls hand their events to `Harness.follow_up/2`,
  which opens runs whose model comes from `agents.<x>.model`.
  """

  alias Omunculus.{Config, Harness, Project}
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, term}
  def run(argv, cwd) do
    with {:ok, config_path, rest} <- split_config(argv, cwd) do
      case rest do
        [] -> {:error, :no_tool}
        [name | args] -> dispatch_named(name, args, config_path)
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

  def format_error({:models, :missing}) do
    "omunculus.toml is missing [models]"
  end

  def format_error({:store, :missing}) do
    "omunculus.toml is missing [store]"
  end

  def format_error({:execution, {:sandbox, :missing}}) do
    "omunculus.toml is missing [execution.sandbox]"
  end

  def format_error({:agent, name, {:invalid, :model}}) do
    "omunculus.toml agent #{name} is missing model"
  end

  def format_error(reason), do: inspect(reason)

  defp split_config(["--config"], _cwd), do: {:error, {:missing_value, "config"}}

  defp split_config(["--config", path | rest], cwd),
    do: {:ok, Path.expand(path, cwd), rest}

  defp split_config(argv, cwd),
    do: {:ok, Path.expand("omunculus.toml", cwd), argv}

  defp dispatch_named(name, args, config_path) do
    dir = Path.dirname(config_path)
    catalog = Catalog.unconfigured()

    case Map.get(catalog, name) do
      %Manifest{config: false} = manifest ->
        project = %Project{dir: dir, conn: nil, config_path: config_path}
        run_tool(manifest, name, args, project, false)

      _other ->
        with {:ok, config} <- Config.load(config_path),
             {:ok, project} <- Project.open(config) do
          try do
            with {:ok, manifest} <- Harness.manifest(project, name) do
              run_tool(manifest, name, args, project, true)
            end
          after
            Project.close(project)
          end
        end
    end
  end

  defp run_tool(manifest, name, rest, project, follow_up?) do
    with {:ok, args} <- build_args(rest, manifest),
         ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil},
         {:ok, out, events} <- Harness.dispatch(project, name, args, ctx),
         :ok <- maybe_follow_up(follow_up?, project, events) do
      if out.ok, do: {:ok, out.output}, else: {:error, {:tool_failed, out.output}}
    end
  end

  defp maybe_follow_up(true, project, events), do: Harness.follow_up(project, events)
  defp maybe_follow_up(false, _project, _events), do: :ok

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
