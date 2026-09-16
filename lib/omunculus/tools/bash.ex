defmodule Omunculus.Tools.Bash do
  @moduledoc """
  `bash` tool, shipped only by the `codex-like` preset (spec §9.4): runs
  `command` through `sh -c` at the run's first root and returns the
  captured stdout/stderr.
  """

  alias Omunculus.Execution.Policy
  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args, roots: roots}) do
    case Args.missing(args, ~w(command)) do
      nil -> exec(roots, args["command"])
      message -> Out.fail(message)
    end
  end

  @spec run(map, Policy.t()) :: map
  def run(input, %Policy{}), do: run(input)

  defp exec([], _command), do: Out.fail("no root")

  defp exec(roots, command) do
    case System.cmd("sh", ["-c", command], cd: hd(roots), stderr_to_stdout: true) do
      {output, 0} -> Out.ok(output)
      {output, status} -> Out.fail(output <> "\n(exit #{status})")
    end
  end
end
