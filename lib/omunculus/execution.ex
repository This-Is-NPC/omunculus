defmodule Omunculus.Execution do
  @moduledoc """
  Starts commands through the backend fixed by an execution policy.
  """

  alias Omunculus.Execution.{Bubblewrap, Command, Policy, Process}

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:pid, :ref]
    defstruct @enforce_keys
  end

  @type result :: %{stdout: binary, stderr: binary, status: non_neg_integer}

  @spec start(Command.t(), Policy.t(), pid, reference) :: {:ok, Handle.t()} | {:error, term}
  def start(command, policy, owner \\ self(), ref \\ make_ref()) do
    with {:ok, backend} <- backend(policy.backend),
         {:ok, pid} <- Process.start(command, policy, owner, ref, backend) do
      {:ok, %Handle{pid: pid, ref: ref}}
    end
  end

  @spec write(Handle.t(), iodata) :: :ok | {:error, term}
  def write(%Handle{pid: pid}, data), do: Process.write(pid, data)

  @spec close_input(Handle.t()) :: :ok | {:error, term}
  def close_input(%Handle{pid: pid}), do: Process.close_input(pid)

  @spec stop(Handle.t(), term) :: :ok | {:error, term}
  def stop(%Handle{pid: pid}, reason), do: Process.stop(pid, reason)

  @spec run(Command.t(), Policy.t(), iodata) :: {:ok, result} | {:error, term}
  def run(command, policy, input \\ "") do
    ref = make_ref()

    with {:ok, handle} <- start(command, policy, self(), ref),
         :ok <- write(handle, input),
         :ok <- close_input(handle) do
      deadline = System.monotonic_time(:millisecond) + policy.limits.timeout_ms
      collect(handle, deadline, "", "")
    end
  end

  defp collect(handle, deadline, stdout, stderr) do
    receive do
      {:execution, ref, {:stdout, bytes}} when ref == handle.ref ->
        collect(handle, deadline, stdout <> bytes, stderr)

      {:execution, ref, {:stderr, bytes}} when ref == handle.ref ->
        collect(handle, deadline, stdout, stderr <> bytes)

      {:execution, ref, {:exit, 0}} when ref == handle.ref ->
        {:ok, %{stdout: stdout, stderr: stderr, status: 0}}

      {:execution, ref, {:exit, status}} when ref == handle.ref ->
        {:error, {:exit, status, stdout, stderr}}

      {:execution, ref, {:error, reason}} when ref == handle.ref ->
        {:error, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        :ok = stop(handle, :timeout)
        {:error, :timeout}
    end
  end

  defp backend("bubblewrap"), do: {:ok, Bubblewrap}
  defp backend(name), do: {:error, {:backend, name}}
end
