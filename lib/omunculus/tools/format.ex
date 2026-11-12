defmodule Omunculus.Tools.Format do
  @moduledoc """
  What the file tools (`write`, `edit`, `patch`) do after they write: run
  the formatter `[settings.format]` names for each written file's extension,
  as a command inside the run's sandbox under its policy. The table maps an
  extension, without its dot, to a command, a list of strings in which
  `{file}` stands for the file's path: `ex = ["mix", "format", "{file}"]`.
  The command runs in the workspace root. A file whose extension the table
  does not list, and a project without the table, are left as written.

  The file stays as written when the formatter fails; the tool's output
  says so in words, with what the command printed, up to `[execution]
  max_output_bytes`. When the formatter changed the file, the output says
  that too, so the model reads it again.
  """

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy}
  alias Omunculus.Tools.Out

  @doc "The lines for the tool's output about formatting `files` (absolute paths), `\"\"` when there is nothing to say."
  @spec run(map, [String.t()], Policy.t()) :: String.t()
  def run(settings, files, %Policy{} = policy) do
    files
    |> Enum.flat_map(&List.wrap(format(settings, &1, policy)))
    |> Enum.join("\n")
  end

  defp format(settings, file, policy) do
    extension = file |> Path.extname() |> String.trim_leading(".")
    path = Path.relative_to(file, policy.workspace.root)

    case Map.fetch(settings, extension) do
      :error -> nil
      {:ok, argv} -> run_command(argv, extension, file, path, policy)
    end
  end

  defp run_command([_ | _] = argv, extension, file, path, policy) do
    if Enum.all?(argv, &is_binary/1) and Enum.any?(argv, &String.contains?(&1, "{file}")),
      do: execute(argv, file, path, policy),
      else: Out.format_unusable(path, extension)
  end

  defp run_command(_argv, extension, _file, path, _policy),
    do: Out.format_unusable(path, extension)

  # `exec "$@"` finds the program on the sandbox's own PATH, as `bash` does.
  defp execute(argv, file, path, policy) do
    name = argv |> Enum.map(&String.replace(&1, "{file}", path)) |> Enum.join(" ")
    args = Enum.map(argv, &String.replace(&1, "{file}", file))
    before = File.read(file)

    {:ok, command} =
      Command.new("/usr/bin/sh", ["-c", ~S(exec "$@"), "sh" | args], cwd: policy.workspace.root)

    case Execution.run(command, policy) do
      {:ok, _result} ->
        if File.read(file) != before, do: Out.formatted(path, name)

      {:error, {:exit, status, stdout, stderr}} ->
        output = Out.cut(stdout <> stderr, policy.limits.max_output_bytes)
        Out.format_failed(path, name, "exited with status #{status}", output)

      {:error, :timeout} ->
        Out.format_failed(path, name, "ran past the run's timeout and was killed", "")

      {:error, reason} ->
        Out.format_failed(path, name, "did not run (#{inspect(reason)})", "")
    end
  end
end
