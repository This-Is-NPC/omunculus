defmodule Omunculus.Runner do
  @moduledoc """
  The one place `update` and `setup` start external commands (`pacman`,
  `sudo`, `systemctl`). Tests point `:omunculus, :runner` at a module with
  the same two functions.
  """

  @callback run(String.t(), [String.t()]) :: {String.t(), non_neg_integer}
  @callback run_tty(String.t(), [String.t()]) :: non_neg_integer

  @doc "Runs the command and returns its output, stderr included, and its exit status."
  @spec run(String.t(), [String.t()]) :: {String.t(), non_neg_integer}
  def run(command, args) do
    case System.find_executable(command) do
      nil -> {"#{command}: command not found", 127}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  @doc "Runs the command on the terminal, so it can ask for a password, and returns its exit status."
  @spec run_tty(String.t(), [String.t()]) :: non_neg_integer
  def run_tty(command, args) do
    case System.find_executable(command) do
      nil ->
        127

      path ->
        port = Port.open({:spawn_executable, path}, [:nouse_stdio, :exit_status, args: args])

        receive do
          {^port, {:exit_status, status}} -> status
        end
    end
  end
end
