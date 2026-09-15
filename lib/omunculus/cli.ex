defmodule Omunculus.CLI do
  @moduledoc """
  The binary's dispatch, per spec §7: `omunculus <name> [args]` opens the
  project at a directory, resolves `args` from the remaining argv and
  calls the same contract the model uses, with `trigger: "cli"`.
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
         ctx = %{trigger: "cli", run_id: nil, work_id: nil, author: "human", model: model},
         {:ok, out} <- Harness.dispatch(project, name, args, ctx) do
      if out.ok, do: {:ok, out.output}, else: {:error, {:tool_failed, out.output}}
    end
  end

  defp build_args([], _manifest), do: {:ok, %{}}
  defp build_args(["--" <> _ | _] = rest, _manifest), do: parse_flags(rest, %{})

  defp build_args([value], manifest) do
    case Map.get(manifest.parameters, "required") do
      [key | _] -> {:ok, %{key => value}}
      _ -> {:error, {:positional, value}}
    end
  end

  defp build_args([value | _rest], _manifest), do: {:error, {:positional, value}}

  defp parse_flags([], acc), do: {:ok, acc}

  defp parse_flags(["--" <> key, value | rest], acc),
    do: parse_flags(rest, Map.put(acc, key, value))

  defp parse_flags(["--" <> key], _acc), do: {:error, {:missing_value, key}}
  defp parse_flags([value | _rest], _acc), do: {:error, {:positional, value}}
end
