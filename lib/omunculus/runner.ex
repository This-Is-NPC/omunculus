defmodule Omunculus.Runner do
  @moduledoc """
  The one place `update` and `setup` start external commands (`pacman`,
  `sudo`, `systemctl`). Tests point `:omunculus, :runner` at a module with
  the same functions.
  """

  @callback run(String.t(), [String.t()]) :: {String.t(), non_neg_integer}
  @callback run_tty(String.t(), [String.t()]) :: non_neg_integer
  @callback tty?() :: boolean

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

  @doc "True when there is a terminal for a command to ask on."
  @spec tty?() :: boolean
  def tty?, do: terminal() != nil

  @doc "Runs the command with its input on the terminal when there is one, and returns its exit status."
  @spec run_tty(String.t(), [String.t()]) :: non_neg_integer
  def run_tty(command, args) do
    case System.find_executable(command) do
      nil ->
        127

      path ->
        {exe, argv} =
          case terminal() do
            nil -> {path, args}
            tty -> {"/bin/sh", ["-c", "exec \"$@\" <\"$0\"", tty, path | args]}
          end

        port = Port.open({:spawn_executable, exe}, [:nouse_stdio, :exit_status, args: argv])

        receive do
          {^port, {:exit_status, status}} -> status
        end
    end
  end
end
