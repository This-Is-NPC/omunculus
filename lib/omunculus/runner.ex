defmodule Omunculus.Runner do
  @moduledoc """
  The one place `update` and `setup` start external commands (`pacman`,
  `sudo`, `systemctl`). Tests point `:omunculus, :runner` at a module with
  the same functions.
  """

  @callback run(String.t(), [String.t()]) :: {String.t(), non_neg_integer}
  @callback run_tty(String.t(), [String.t()], keyword) :: non_neg_integer
  @callback terminal() :: String.t() | nil
  @callback executable(String.t()) :: String.t() | nil
  @callback finish(String.t()) :: no_return

  @doc "Prints the message and ends the program with status 0, loading no more code."
  @spec finish(String.t()) :: no_return
  def finish(message) do
    IO.puts(message)
    System.halt(0)
  end

  @doc "Runs the command and returns its output, stderr included, and its exit status."
  @spec run(String.t(), [String.t()]) :: {String.t(), non_neg_integer}
  def run(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command}: command not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  @doc """
  The terminal device the program runs on (`/dev/pts/N` or `/dev/ttyN`),
  read from its standard streams, or nil without one. A child started
  through a port has no controlling terminal, so `/dev/tty` is no use there.
  """
  @spec terminal() :: String.t() | nil
  def terminal do
    Enum.find_value(0..2, fn fd ->
      with {:ok, path} <- File.read_link("/proc/self/fd/#{fd}"),
           true <- String.match?(path, ~r{^/dev/(pts/\d+|tty\d+)$}),
           do: path,
           else: (_ -> nil)
    end)
  end

  @doc "The path of the command on the search path, or nil."
  @spec executable(String.t()) :: String.t() | nil
  def executable(command), do: System.find_executable(command)

  @doc """
  Runs the command with its input on the terminal when there is one, and
  returns its exit status. With `echo: false` the terminal does not show what
  is typed while it runs (a password), and gets its echo and a newline back
  afterwards, whatever the command did.
  """
  @spec run_tty(String.t(), [String.t()], keyword) :: non_neg_integer
  def run_tty(command, args, opts \\ []) do
    case System.find_executable(command) do
      nil ->
        127

      path ->
        {exe, argv} = spawn(terminal(), path, args, Keyword.get(opts, :echo, true))
        port = Port.open({:spawn_executable, exe}, [:nouse_stdio, :exit_status, args: argv])

        receive do
          {^port, {:exit_status, status}} -> status
        end
    end
  end

  defp spawn(nil, path, args, _echo), do: {path, args}

  defp spawn(tty, path, args, true),
    do: {"/bin/sh", ["-c", ~s(exec "$@" <"$0"), tty, path | args]}

  # Without stty the password would show, so the command does not run.
  defp spawn(tty, path, args, false) do
    script = """
    stty -echo <"$0" || exit 1
    trap 'stty echo <"$0"' EXIT
    trap 'exit 130' INT TERM
    "$@" <"$0"
    status=$?
    stty echo <"$0"
    echo >&2
    exit $status
    """

    {"/bin/sh", ["-c", script, tty, path | args]}
  end
end
