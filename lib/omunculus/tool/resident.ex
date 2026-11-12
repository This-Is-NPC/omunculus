defmodule Omunculus.Tool.Resident do
  @moduledoc """
  The process of a tool kept between the calls of one run: that of a tool
  whose manifest sets `keep_alive_ms`, or the shell of `bash`. A call is one
  line on its stdin, for a tool the `in` of the contract as JSON; the answer
  is one line on its stdout. The process is started, under the run's policy,
  by the first call and ends after `keep_alive_ms` without a call (never,
  without it), when the process that first called it ends, on a failed call,
  or when it exits; the next call starts it again. One run never reaches the
  process of another.

  A call has `timeout_ms`, the policy's without one. Past it, what runs
  below the process is killed (`Execution.interrupt/1`): if the process then
  answers, within a second, it is kept and the call fails with
  `:interrupted`; if not, it is stopped and the call fails with `:timeout`.
  """

  use GenServer

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy, Session}

  @registry __MODULE__.Registry

  @grace_ms 1_000

  @spec call(term, Command.t(), String.t(), Policy.t(), keyword) ::
          {:ok, String.t()} | {:error, term}
  def call(key, command, line, policy, options) do
    timeout_ms = Keyword.get(options, :timeout_ms, policy.limits.timeout_ms)

    with {:ok, pid} <- ensure(key, command, policy, Keyword.get(options, :keep_alive_ms)) do
      GenServer.call(pid, {:call, line, timeout_ms}, :infinity)
    end
  catch
    # The process ended between finding it and calling it.
    :exit, {reason, _call} when reason in [:noproc, :normal] ->
      call(key, command, line, policy, options)
  end

  defp ensure(key, command, policy, keep_alive_ms) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, {key, command, policy, keep_alive_ms, self()}}

        case DynamicSupervisor.start_child(__MODULE__.Supervisor, spec) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def start_link({key, _command, _policy, _keep_alive_ms, _owner} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, key}})

  def child_spec(args),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  @impl true
  def init({_key, command, policy, keep_alive_ms, owner}) do
    case Execution.start(command, policy, self(), make_ref(), :resident) do
      {:ok, handle} ->
        {:ok,
         idle(%{
           handle: handle,
           keep_alive_ms: keep_alive_ms,
           timer: nil,
           owner: Process.monitor(owner)
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, line, timeout_ms}, _from, state) do
    cancel_idle(state)

    with :ok <- Execution.write(state.handle, line <> "\n"),
         {:ok, answer} <- read(state.handle, deadline(timeout_ms)) do
      {:reply, {:ok, answer}, idle(state)}
    else
      {:error, :timeout} -> interrupt(state)
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  defp interrupt(state) do
    :ok = Execution.interrupt(state.handle)

    case read(state.handle, deadline(@grace_ms)) do
      {:ok, _answer} -> {:reply, {:error, :interrupted}, idle(state)}
      {:error, _reason} -> {:stop, :normal, {:error, :timeout}, state}
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # The process ending, or the idle time passing, between calls, or the
  # process of the run that started it.
  @impl true
  def handle_info({:execution, ref, _event}, %{handle: %{ref: ref}} = state),
    do: {:stop, :normal, state}

  def handle_info(:idle, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner: monitor} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state), do: Session.stop(state.handle)

  defp idle(%{keep_alive_ms: nil} = state), do: state

  defp idle(state),
    do: %{state | timer: Process.send_after(self(), :idle, state.keep_alive_ms)}

  defp cancel_idle(%{timer: nil}), do: :ok
  defp cancel_idle(%{timer: timer}), do: Process.cancel_timer(timer)

  defp read(handle, deadline) do
    Session.serve(handle, deadline, &{:halt, {:ok, &1}}, fn
      {:exit, status} -> {:error, {:exit, status, "", "the tool's process exited"}}
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, :timeout}
    end)
  end
end
