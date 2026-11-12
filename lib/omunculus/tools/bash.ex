defmodule Omunculus.Tools.Bash do
  @moduledoc """
  `bash` tool, shipped only by the `codex-like` preset: runs `command` as an
  `sh` script in the run's shell and returns the captured output. The shell
  is one `sh` in the run's sandbox, kept by `Tool.Resident` for the run: the
  calls share its directory, variables and functions, and the sandbox is
  built once. A command is written to a file of the run's scratch, which the
  shell sources with stdout and stderr to a file beside it, answering with
  the status; the output is read from there, at most `max_output_bytes`.

  A call changes to `workdir`, relative to the workspace root, when given. It
  runs for at most `timeout_ms`: the policy's `timeout_ms` without one, and
  at most `max_timeout_ms` of `[settings.bash]`, which is `timeout_ms`
  without one. A command past it is killed and says so; the shell stays
  open. A command that fails in a run without `sandbox.write` is told the
  workspace is read-only there.
  """

  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Id
  alias Omunculus.Tool.Resident
  alias Omunculus.Tools.{Args, Out}

  # Reads the path of a command file, sources it with its output to
  # `<path>.out` and prints the status. A syntax error is found beforehand,
  # for `.` would end the shell on it; stdin is closed for the command.
  @loop ~S"""
  while IFS= read -r __omu_file; do
    if /usr/bin/sh -n "$__omu_file" 2> "$__omu_file.out"; then
      . "$__omu_file" < /dev/null > "$__omu_file.out" 2>&1
      __omu_status=$?
    else
      __omu_status=2
    fi
    printf '%d\n' "$__omu_status"
  done
  """

  @spec run(map, Policy.t()) :: map
  def run(%{args: args, view: view}, %Policy{} = policy) do
    with nil <- Args.missing(args, ~w(command)),
         {:ok, workdir} <- workdir(policy, args["workdir"]),
         {:ok, timeout_ms} <- timeout(policy, view, args["timeout_ms"]) do
      exec(policy, args["command"], workdir, timeout_ms)
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp workdir(_policy, nil), do: {:ok, nil}

  defp workdir(policy, path) when is_binary(path) do
    absolute = Path.expand(path, policy.workspace.root)

    if File.dir?(absolute) and Policy.readable?(policy, absolute),
      do: {:ok, absolute},
      else: {:error, "workdir is not a directory the run can read: #{path}"}
  end

  defp workdir(_policy, _path), do: {:error, "workdir must be a path"}

  defp timeout(policy, _view, nil), do: {:ok, policy.limits.timeout_ms}

  defp timeout(policy, view, ms) when is_integer(ms) and ms > 0 do
    max = max(get_in(view, ["bash", "max_timeout_ms"]) || 0, policy.limits.timeout_ms)

    if ms <= max, do: {:ok, ms}, else: {:error, Out.timeout_too_long(max)}
  end

  defp timeout(_policy, _view, _ms), do: {:error, "timeout_ms must be a positive integer"}

  defp exec(%Policy{scratch: scratch}, _source, _workdir, _timeout_ms)
       when not is_binary(scratch),
       do: Out.fail("execution failed: the run has no scratch")

  defp exec(policy, source, workdir, timeout_ms) do
    directory = Path.join(policy.scratch, ".shell")
    name = "command-" <> Id.new()
    file = Path.join(directory, name)
    cd = if workdir, do: "cd -- #{quote_word(workdir)} || return\n", else: ""

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(file, cd <> source <> "\n"),
         {:ok, shell} <-
           Command.new("/usr/bin/sh", [],
             cwd: policy.workspace.root,
             script: @loop,
             home: ".home-shell"
           ) do
      answer =
        Resident.call({policy.id, "bash"}, shell, "/tmp/.shell/" <> name, policy,
          timeout_ms: timeout_ms
        )

      output = read_output(file <> ".out", policy.limits.max_output_bytes)
      File.rm(file)
      File.rm(file <> ".out")
      report(policy, answer, output, timeout_ms)
    else
      {:error, reason} -> Out.fail("execution failed: #{inspect(reason)}")
    end
  end

  defp report(policy, {:ok, status}, {output, truncated}, _timeout_ms) do
    case String.to_integer(String.trim(status)) do
      0 ->
        Out.ok(
          output <> truncated <> refused_write(policy, output) <> closed_network(policy, output)
        )

      status ->
        Out.fail(
          output <>
            truncated <>
            "\n(exit #{status})" <> read_only(policy) <> closed_network(policy, output)
        )
    end
  end

  defp report(_policy, {:error, :interrupted}, {output, truncated}, timeout_ms),
    do: Out.fail(output <> truncated <> "\n" <> Out.command_timed_out(timeout_ms, false))

  defp report(_policy, {:error, :timeout}, {output, truncated}, timeout_ms),
    do: Out.fail(output <> truncated <> "\n" <> Out.command_timed_out(timeout_ms, true))

  defp report(_policy, {:error, {:exit, status, _stderr, _message}}, {output, truncated}, _ms),
    do: Out.fail(output <> truncated <> "\n" <> Out.shell_ended(status))

  defp report(_policy, {:error, reason}, _output, _timeout_ms),
    do: Out.fail("execution failed: #{inspect(reason)}")

  defp read_output(path, limit) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        data = IO.binread(device, limit + 1)
        File.close(device)

        if is_binary(data) and byte_size(data) > limit,
          do: {binary_part(data, 0, limit), "\n" <> Out.output_truncated(limit)},
          else: {if(is_binary(data), do: data, else: ""), ""}

      {:error, _reason} ->
        {"", ""}
    end
  end

  defp quote_word(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

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
