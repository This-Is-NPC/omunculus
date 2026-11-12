defmodule Omunculus.Tool.Resident do
  @moduledoc """
  The process of a tool whose manifest sets `keep_alive_ms`, kept between
  the calls of one run. A call is one line of JSON on its stdin, the
  `in` of the contract; the answer is one line of JSON on its stdout, the
  `out`. The process is started, under the run's policy, by the first call
  and ends after `keep_alive_ms` without a call, on a failed call, or when
  it exits; the next call starts it again. One run never reaches the
  process of another.
  """

  use GenServer

  alias Omunculus.Execution
  alias Omunculus.Execution.{Command, Policy, Session}

  @registry __MODULE__.Registry

  @spec call({String.t(), String.t()}, Command.t(), String.t(), Policy.t(), pos_integer) ::
          {:ok, String.t()} | {:error, term}
  def call(key, command, line, policy, keep_alive_ms) do
    with {:ok, pid} <- ensure(key, command, policy, keep_alive_ms) do
      GenServer.call(pid, {:call, line, Policy.deadline(policy)}, :infinity)
    end
  catch
    # The process ended between finding it and calling it.
    :exit, {reason, _call} when reason in [:noproc, :normal] ->
      call(key, command, line, policy, keep_alive_ms)
  end

  defp ensure(key, command, policy, keep_alive_ms) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, {key, command, policy, keep_alive_ms}}

        case DynamicSupervisor.start_child(__MODULE__.Supervisor, spec) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def start_link({key, _command, _policy, _keep_alive_ms} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, key}})

  def child_spec(args),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :temporary}

  @impl true
  def init({_key, command, policy, keep_alive_ms}) do
    case Execution.start(command, policy) do
      {:ok, handle} -> {:ok, idle(%{handle: handle, keep_alive_ms: keep_alive_ms, timer: nil})}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, line, deadline}, _from, state) do
    Process.cancel_timer(state.timer)

    with :ok <- Execution.write(state.handle, line <> "\n"),
         {:ok, answer} <- read(state.handle, deadline) do
      {:reply, {:ok, answer}, idle(state)}
    else
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  # The process ending, or the idle time passing, between calls.
  @impl true
  def handle_info({:execution, ref, _event}, %{handle: %{ref: ref}} = state),
    do: {:stop, :normal, state}

  def handle_info(:idle, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state), do: Session.stop(state.handle)

  defp idle(state),
    do: %{state | timer: Process.send_after(self(), :idle, state.keep_alive_ms)}

  defp read(handle, deadline) do
    Session.serve(handle, deadline, &{:halt, {:ok, &1}}, fn
      {:exit, status} -> {:error, {:exit, status, "", "the tool's process exited"}}
      {:error, reason} -> {:error, reason}
      :timeout -> {:error, :timeout}
    end)
  end
end
