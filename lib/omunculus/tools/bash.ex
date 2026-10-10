defmodule Omunculus.Tools.Bash do
  @moduledoc """
  `bash` tool, shipped only by the `codex-like` preset (spec §9.4): runs
  `command` through `sh -c` in the immutable run policy and returns the
  captured output. A command that fails in a run without `sandbox.write`
  is told the workspace is read-only there.
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
        Out.fail(stdout <> stderr <> "\n(exit #{status})" <> read_only(policy))

      {:error, reason} ->
        Out.fail("execution failed: #{inspect(reason)}")
    end
  end

  defp read_only(%Policy{read_write: []}), do: "\n" <> Out.read_only_workspace()
  defp read_only(_policy), do: ""
end
