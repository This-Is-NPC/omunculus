defmodule Omunculus.Runner do
  @moduledoc """
  The one place `update` and `setup` start external commands (`pacman`,
  `sudo`, `systemctl`). Tests point `:omunculus, :runner` at a module with
  the same three functions.
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

  @doc "True when /dev/tty can be opened for reading, so a command can ask on the terminal."
  @spec tty?() :: boolean
  def tty?, do: match?({:ok, _}, File.open("/dev/tty", [:read]) |> close())

  defp close({:ok, io} = opened), do: tap(opened, fn _ -> File.close(io) end)
  defp close(error), do: error

  @doc "Runs the command with its input on the terminal when there is one, and returns its exit status."
  @spec run_tty(String.t(), [String.t()]) :: non_neg_integer
  def run_tty(command, args) do
    case System.find_executable(command) do
      nil ->
        127

      path ->
        {exe, argv} =
          if tty?(),
            do: {"/bin/sh", ["-c", "exec \"$@\" </dev/tty", "sh", path | args]},
            else: {path, args}

        port = Port.open({:spawn_executable, exe}, [:nouse_stdio, :exit_status, args: argv])

        receive do
          {^port, {:exit_status, status}} -> status
        end
    end
  end
end
