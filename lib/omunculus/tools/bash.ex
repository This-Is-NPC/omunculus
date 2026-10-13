defmodule Omunculus.Tools.Bash do
  @moduledoc """
  `bash` tool, shipped only by the `codex-like` preset: runs
  `command` through `sh -c` in the immutable run policy and returns the
  captured output. It starts in `workdir`, relative to the workspace root,
  or in that root without one. A command that fails in a run without `sandbox.write`
  is told the workspace is read-only there.
  """

  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Execution
  alias Omunculus.Tools.{Args, Out}

  @spec run(map, Policy.t()) :: map
  def run(%{args: args}, %Policy{} = policy) do
    with nil <- Args.missing(args, ~w(command)),
         {:ok, workdir} <- workdir(policy, args["workdir"]) do
      exec(policy, args["command"], workdir)
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp workdir(policy, nil), do: {:ok, policy.workspace.root}

  defp workdir(policy, path) when is_binary(path) do
    absolute = Path.expand(path, policy.workspace.root)

    if File.dir?(absolute) and Policy.readable?(policy, absolute),
      do: {:ok, absolute},
      else: {:error, "workdir is not a directory the run can read: #{path}"}
  end

  defp workdir(_policy, _path), do: {:error, "workdir must be a path"}

  defp exec(policy, source, workdir) do
    with {:ok, command} <- Command.new("/usr/bin/sh", ["-c", source], cwd: workdir),
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
  # have: no name resolves, no connection opens, not even to localhost.
  @offline ~r/name resolution|Could not resolve|Network is unreachable|Failed to establish a new connection|Temporary failure|getaddrinfo|No address associated|Connection refused|Failed to connect|Could not connect/i

  defp closed_network(%Policy{network: "none"}, output),
    do: if(Regex.match?(@offline, output), do: "\n" <> Out.closed_network(), else: "")

  defp closed_network(_policy, _output), do: ""

  # A command that went on after a write the sandbox refused still exits 0.
  defp refused_write(policy, output),
    do: if(String.contains?(output, "Read-only file system"), do: read_only(policy), else: "")
end
