defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` resolves
  `--config <path>` (default `./omunculus.toml` in the given cwd) and
  calls the same contract the model uses, with `trigger: "cli"`. The
  project root is the config file's directory, or `[project] root`
  relative to it. Tools with `config = false` run without opening the
  store. Configured calls hand their events to `Harness.follow_up/3`,
  driven by the given `model`. `main/1` is the only caller that reads
  the process environment: `OMUNCULUS_MODEL` — `fake` (default),
  `battery` or `openai`, the last built from `OMUNCULUS_OPENAI_URL`,
  `OMUNCULUS_OPENAI_MODEL` and an optional `OMUNCULUS_OPENAI_KEY` sent
  as a bearer header — for the model; `run/3` never touches global
  state.
  """

  alias Omunculus.{Config, Harness, Project}
  alias Omunculus.Model.{Battery, Fake, OpenAI}
  alias Omunculus.Tool.{Catalog, Manifest}

  @spec run([String.t()], String.t(), (String.t(), [map], fun ->
                                         {:ok, String.t()} | {:error, term})) ::
          {:ok, String.t()} | {:error, term}
  def run(argv, cwd, model) do
    with {:ok, config_path, rest} <- split_config(argv, cwd) do
      case rest do
        [] -> {:error, :no_tool}
        [name | args] -> dispatch_named(name, args, config_path, model)
      end
    end
  end

  @spec main([String.t()]) :: :ok
  def main(argv) do
    case run(argv, File.cwd!(), model_from_env()) do
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

  def format_error(reason), do: inspect(reason)

  defp split_config(["--config"], _cwd), do: {:error, {:missing_value, "config"}}

  defp split_config(["--config", path | rest], cwd),
    do: {:ok, Path.expand(path, cwd), rest}

  defp split_config(argv, cwd),
    do: {:ok, Path.expand("omunculus.toml", cwd), argv}

  defp dispatch_named(name, args, config_path, model) do
    dir = Path.dirname(config_path)
    catalog = Catalog.unconfigured()

    case Map.get(catalog, name) do
      %Manifest{config: false} = manifest ->
        project = %Project{dir: dir, conn: nil, config_path: config_path}
        run_tool(manifest, name, args, project, model, false)

      _other ->
        with {:ok, config} <- Config.load(config_path),
             {:ok, project} <- Project.open(config.root, config_path) do
          try do
            with {:ok, manifest} <- Harness.manifest(project, name) do
              run_tool(manifest, name, args, project, model, true)
            end
          after
            Project.close(project)
          end
        end
    end
  end

  defp run_tool(manifest, name, rest, project, model, follow_up?) do
    with {:ok, args} <- build_args(rest, manifest),
         ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil},
         {:ok, out, events} <- Harness.dispatch(project, name, args, ctx),
         :ok <- maybe_follow_up(follow_up?, project, events, model) do
      if out.ok, do: {:ok, out.output}, else: {:error, {:tool_failed, out.output}}
    end
  end

  defp maybe_follow_up(true, project, events, model),
    do: Harness.follow_up(project, events, model)

  defp maybe_follow_up(false, _project, _events, _model), do: :ok

  defp model_from_env do
    case System.get_env("OMUNCULUS_MODEL", "fake") do
      "battery" -> &Battery.complete/3
      "openai" -> openai_model_from_env()
      _fake -> &Fake.complete/3
    end
  end

  defp openai_model_from_env do
    url = System.fetch_env!("OMUNCULUS_OPENAI_URL")
    model_name = System.fetch_env!("OMUNCULUS_OPENAI_MODEL")
    OpenAI.new(url, model_name, headers: bearer_header())
  end

  defp bearer_header do
    case System.get_env("OMUNCULUS_OPENAI_KEY") do
      nil -> []
      key -> [{"authorization", "Bearer " <> key}]
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
