defmodule Omunculus.Tools.Bash do
  @moduledoc """
  `bash` tool, shipped only by the `codex-like` preset (spec §9.4): runs
  `command` through `sh -c` in the immutable run policy and returns the
  captured output.
  """

  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Execution
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args}, %Policy{} = policy) do
    case Args.missing(args, ~w(command)) do
      nil -> exec(policy, args["command"])
      message -> Out.fail(message)
    end
  end

  defp exec(policy, source) do
    with {:ok, command} <- Command.new("/usr/bin/sh", ["-c", source], cwd: policy.workspace.root),
         {:ok, result} <- Execution.run(command, policy) do
      Out.ok(result.stdout <> result.stderr)
    else
      {:error, {:exit, status, stdout, stderr}} ->
        Out.fail(stdout <> stderr <> "\n(exit #{status})")

      {:error, reason} ->
        Out.fail("execution failed: #{inspect(reason)}")
    end
  end
end
