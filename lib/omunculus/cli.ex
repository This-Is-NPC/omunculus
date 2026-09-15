defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` opens the
  project at a directory, resolves `args` from the remaining argv and
  calls the same contract the model uses, with `trigger: "cli"`. Once the
  call is recorded, hands its events to `Harness.follow_up/3` so any run
  the call's action asks for opens before the CLI returns.
  """

  alias Omunculus.{Harness, Project}

  @spec run([String.t()], String.t()) :: {:ok, String.t()} | {:error, term}
  def run([], _dir), do: {:error, :no_tool}

  def run([name | rest], dir) do
    with {:ok, project} <- Project.open(dir) do
      try do
        dispatch(project, name, rest)
      after
        Project.close(project)
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
        IO.puts(:stderr, inspect(reason))
        System.halt(1)
    end
  end

  defp dispatch(project, name, rest) do
    model = Application.get_env(:omunculus, :model, &Omunculus.Model.Fake.complete/2)

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
