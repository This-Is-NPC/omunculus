defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` opens the
  project at a directory, resolves `args` from the remaining argv and
  calls the same contract the model uses, with `trigger: "cli"`. Once the
  call is recorded, hands its events to `Harness.follow_up/3`, driven by
  the given `model`, so any run the call's action asks for opens before
  the CLI returns. `main/1` is the only caller that reads the process
  environment: `OMUNCULUS_PROJECT` for the project directory (default
  `File.cwd!()`) and `OMUNCULUS_MODEL` — `fake` (default), `battery` or
  `openai`, the last built from `OMUNCULUS_OPENAI_URL`,
  `OMUNCULUS_OPENAI_MODEL` and an optional `OMUNCULUS_OPENAI_KEY` sent as
  a bearer header — for the model; `run/3` never touches global state.
  """

  alias Omunculus.{Harness, Project}
  alias Omunculus.Model.{Battery, Fake, OpenAI}

  @spec run([String.t()], String.t(), (String.t(), [map], fun ->
                                         {:ok, String.t()} | {:error, term})) ::
          {:ok, String.t()} | {:error, term}
  def run([], _dir, _model), do: {:error, :no_tool}

  def run([name | rest], dir, model) do
    with {:ok, project} <- Project.open(dir) do
      try do
        dispatch(project, name, rest, model)
      after
        Project.close(project)
      end
    end
  end

  @spec main([String.t()]) :: :ok
  def main(argv) do
    dir = System.get_env("OMUNCULUS_PROJECT", File.cwd!())

    case run(argv, dir, model_from_env()) do
      {:ok, output} ->
        if output != "", do: IO.puts(output)
        :ok

      {:error, reason} ->
        IO.puts(:stderr, inspect(reason))
        System.halt(1)
    end
  end

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

  defp dispatch(project, name, rest, model) do
    with {:ok, manifest} <- Harness.manifest(project, name),
         {:ok, args} <- build_args(rest, manifest),
         ctx = %{trigger: "cli", run_id: nil, author: "human", agent: nil},
         {:ok, out, events} <- Harness.dispatch(project, name, args, ctx),
         :ok <- Harness.follow_up(project, events, model) do
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
