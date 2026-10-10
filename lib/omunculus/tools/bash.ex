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
      output = result.stdout <> result.stderr
      Out.ok(output <> refused_write(policy, output) <> closed_network(policy, output))
    else
      {:error, {:exit, status, stdout, stderr}} ->
        output = stdout <> stderr

        Out.fail(
          output <> "\n(exit #{status})" <> read_only(policy) <> closed_network(policy, output)
        )

      {:error, reason} ->
        Out.fail("execution failed: #{inspect(reason)}")
    end
  end

  defp read_only(%Policy{read_write: []}), do: "\n" <> Out.read_only_workspace()
  defp read_only(_policy), do: ""

  # What a command prints when it reaches for a network the run does not
  # have: no name resolves, no connection opens.
  @offline ~r/name resolution|Could not resolve|Network is unreachable|Failed to establish a new connection|Temporary failure|getaddrinfo|No address associated/i

  defp closed_network(%Policy{network: "none"}, output),
    do: if(Regex.match?(@offline, output), do: "\n" <> Out.closed_network(), else: "")

  defp closed_network(_policy, _output), do: ""

  # A command that went on after a write the sandbox refused still exits 0.
  defp refused_write(policy, output),
    do: if(String.contains?(output, "Read-only file system"), do: read_only(policy), else: "")
end
