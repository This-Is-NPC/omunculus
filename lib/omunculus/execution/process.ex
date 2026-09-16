defmodule Omunculus.Execution.Process do
  @moduledoc false

  use GenServer

  alias Omunculus.Execution.{Command, Limiter, Policy}

  @spec start(Command.t(), Policy.t(), pid, reference, module, reference, Limiter.class()) ::
          {:ok, pid} | {:error, term}
  def start(command, policy, owner, ref, backend, lease, class) do
    DynamicSupervisor.start_child(
      Omunculus.Execution.ProcessSupervisor,
      {__MODULE__, {command, policy, owner, ref, backend, lease, class}}
    )
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  @spec write(pid, iodata) :: :ok | {:error, term}
  def write(pid, data), do: GenServer.call(pid, {:write, data})

  @spec close_input(pid) :: :ok | {:error, term}
  def close_input(pid), do: GenServer.call(pid, :close_input)

  @spec stop(pid, term) :: :ok | {:error, term}
  def stop(pid, reason), do: GenServer.call(pid, {:stop, reason})

  @impl true
  def init({command, policy, owner, ref, backend, lease, class}) do
    Process.flag(:trap_exit, true)

    with {:ok, handle} <- backend.start(command, policy, self(), ref) do
      {:ok,
       %{
         backend: backend,
         handle: handle,
         limits: policy.limits,
         lease: lease,
         class: class,
         owner: owner,
         owner_monitor: Process.monitor(owner),
         ref: ref,
         output_bytes: 0,
         terminal_error: nil,
         exit_status: nil,
         stderr_closed: not Map.has_key?(handle, :stderr_reader),
         released: false
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    reply =
      if state.terminal_error,
        do: {:error, state.terminal_error},
        else: state.backend.write(state.handle, data)

    {:reply, reply, state}
  end

  def handle_call(:close_input, _from, state) do
    reply = state.backend.close_input(state.handle)
    {:reply, reply, state}
  end

  def handle_call({:stop, reason}, _from, state) do
    {:reply, :ok, stop_execution(state, reason)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{handle: %{port: port}} = state) do
    {:noreply, emit(state, {:stdout, data})}
  end

  def handle_info({port, {:data, data}}, %{handle: %{stderr_reader: port}} = state) do
    {:noreply, emit(state, {:stderr, data})}
  end

  def handle_info({port, {:exit_status, status}}, %{handle: %{port: port}} = state) do
    await_exit_status(state, state.backend.exit_status(state.handle, status))
  end

  def handle_info({port, {:exit_status, _status}}, %{handle: %{stderr_reader: port}} = state) do
    finish(%{state | stderr_closed: true})
  end

  def handle_info({:execution, ref, {:stdout, _bytes} = event}, %{ref: ref} = state),
    do: {:noreply, emit(state, event)}

  def handle_info({:execution, ref, {:stderr, _bytes} = event}, %{ref: ref} = state),
    do: {:noreply, emit(state, event)}

  def handle_info({:execution, ref, {:exit, status}}, %{ref: ref} = state) do
    finish(%{state | exit_status: status})
  end

  def handle_info({:execution, ref, {:error, reason}}, %{ref: ref} = state),
    do: {:noreply, stop_execution(state, reason)}

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    {:noreply, stop_execution(state, :owner_down)}
  end

  def handle_info({:EXIT, port, reason}, %{handle: %{port: port}} = state) do
    await_exit_status(state, state.backend.exit_status(state.handle, exit_status(reason)))
  end

  def handle_info({:execution_stderr_timeout, ref}, %{ref: ref} = state) do
    finish(%{state | stderr_closed: true})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_map(state) and not state.released do
      state.backend.stop(state.handle, :owner_stopped)
      state.backend.cleanup(state.handle)
      Limiter.release(state.limits, state.lease, state.class)
    end

    :ok
  end

  defp emit(state, {stream, bytes}) do
    bytes = IO.iodata_to_binary(bytes)
    output_bytes = state.output_bytes + byte_size(bytes)

    if output_bytes > state.limits.max_output_bytes do
      stop_execution(state, :max_output_bytes)
    else
      send(state.owner, {:execution, state.ref, {stream, bytes}})
      %{state | output_bytes: output_bytes}
    end
  end

  defp stop_execution(%{terminal_error: nil} = state, reason) do
    :ok = state.backend.stop(state.handle, reason)
    send(state.owner, {:execution, state.ref, {:error, reason}})
    %{state | terminal_error: reason}
  end

  defp stop_execution(state, _reason), do: state

  defp finish(%{exit_status: nil} = state), do: {:noreply, state}

  defp finish(%{stderr_closed: false} = state), do: {:noreply, state}

  defp finish(state) do
    if is_nil(state.terminal_error) do
      send(state.owner, {:execution, state.ref, {:exit, state.exit_status}})
    end

    state.backend.cleanup(state.handle)
    Limiter.release(state.limits, state.lease, state.class)
    {:stop, :normal, %{state | released: true}}
  end

  defp await_stderr(%{stderr_closed: true} = state), do: finish(state)

  defp await_stderr(state) do
    Process.send_after(self(), {:execution_stderr_timeout, state.ref}, 100)
    {:noreply, state}
  end

  defp await_exit_status(state, {:error, reason}) do
    state
    |> stop_execution(reason)
    |> Map.merge(%{exit_status: 1, stderr_closed: true})
    |> finish()
  end

  defp await_exit_status(state, status), do: await_stderr(%{state | exit_status: status})

  defp exit_status(:normal), do: 0
  defp exit_status({:exit_status, status}) when is_integer(status), do: status
  defp exit_status(_reason), do: 1
end
