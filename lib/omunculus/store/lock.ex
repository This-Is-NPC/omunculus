defmodule Omunculus.Store.Lock do
  @moduledoc "Holds an operating-system lock for a project's store lifetime."

  @marker "OMUNCULUS_LOCK_READY\n"

  @spec acquire(String.t()) :: {:ok, port} | {:error, term}
  def acquire(store_path) do
    case System.find_executable("flock") do
      nil -> {:error, :flock_missing}
      executable -> start_lock(executable, store_path <> ".omunculus.lock")
    end
  end

  defp start_lock(executable, path) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-n", "-F", path, "/bin/sh", "-c", "printf '#{@marker}'; cat >/dev/null"]
      ])

    case await_ready(port, "") do
      :ok ->
        {:ok, port}

      {:error, reason} ->
        release(port)
        {:error, reason}
    end
  end

  defp await_ready(port, output) do
    receive do
      {^port, {:data, chunk}} ->
        output = output <> chunk

        if String.contains?(output, @marker) do
          :ok
        else
          await_ready(port, output)
        end

      {^port, {:exit_status, _status}} ->
        {:error, :project_in_use}
    after
      5_000 -> {:error, :lock_timeout}
    end
  end

  @spec release(port) :: :ok
  def release(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
