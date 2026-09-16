defmodule Omunculus.Execution.Limiter do
  @moduledoc false

  @spec acquire(%{
          max_concurrent: pos_integer,
          max_queue: non_neg_integer,
          queue_timeout_ms: pos_integer
        }) ::
          :ok | {:error, :queue_full | :queue_timeout}
  def acquire(limits) do
    with {:ok, server} <- server(limits) do
      request = make_ref()

      try do
        GenServer.call(server, {:acquire, self(), request}, limits.queue_timeout_ms)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(server, {:cancel, self(), request})
          {:error, :queue_timeout}
      end
    end
  end

  @spec release(%{max_concurrent: pos_integer, max_queue: non_neg_integer}, pid) :: :ok
  def release(limits, pid \\ self()) do
    case Registry.lookup(Omunculus.Execution.Registry, key(limits)) do
      [{server, _}] -> GenServer.cast(server, {:release, pid})
      [] -> :ok
    end

    :ok
  end

  defp server(limits) do
    case Registry.lookup(Omunculus.Execution.Registry, key(limits)) do
      [{server, _}] ->
        {:ok, server}

      [] ->
        child = {__MODULE__.Server, limits}

        case DynamicSupervisor.start_child(Omunculus.Execution.Limiter.Supervisor, child) do
          {:ok, server} -> {:ok, server}
          {:error, {:already_started, server}} -> {:ok, server}
          {:error, reason} -> {:error, {:limiter, reason}}
        end
    end
  end

  defp key(limits), do: {limits.max_concurrent, limits.max_queue}

  defmodule Server do
    @moduledoc false

    use GenServer

    def start_link(limits) do
      GenServer.start_link(__MODULE__, limits,
        name:
          {:via, Registry,
           {Omunculus.Execution.Registry, {limits.max_concurrent, limits.max_queue}}}
      )
    end

    @impl true
    def init(limits) do
      {:ok,
       %{
         max_concurrent: limits.max_concurrent,
         max_queue: limits.max_queue,
         running: %{},
         waiting: :queue.new()
       }}
    end

    @impl true
    def handle_call({:acquire, pid, request}, from, state) do
      cond do
        map_size(state.running) < state.max_concurrent ->
          {:reply, :ok, admit(state, pid, request)}

        :queue.len(state.waiting) >= state.max_queue ->
          {:reply, {:error, :queue_full}, state}

        true ->
          waiting = %{pid: pid, from: from, request: request, monitor: Process.monitor(pid)}
          {:noreply, %{state | waiting: :queue.in(waiting, state.waiting)}}
      end
    end

    @impl true
    def handle_cast({:release, pid}, state),
      do: {:noreply, state |> release(pid) |> admit_waiting()}

    def handle_cast({:cancel, pid, request}, state) do
      state =
        case Map.fetch(state.running, pid) do
          {:ok, %{request: ^request}} -> state |> release(pid) |> admit_waiting()
          _ -> %{state | waiting: remove_waiting(state.waiting, pid, request)}
        end

      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
      state =
        case Map.fetch(state.running, pid) do
          {:ok, %{monitor: ^monitor}} -> state |> release(pid, false) |> admit_waiting()
          _ -> %{state | waiting: remove_waiting(state.waiting, pid, monitor)}
        end

      {:noreply, state}
    end

    defp admit(state, pid, request) do
      running = %{monitor: Process.monitor(pid), request: request}
      %{state | running: Map.put(state.running, pid, running)}
    end

    defp release(state, pid, demonitor \\ true) do
      case Map.pop(state.running, pid) do
        {nil, _running} ->
          state

        {%{monitor: monitor}, running} ->
          if demonitor, do: Process.demonitor(monitor, [:flush])
          %{state | running: running}
      end
    end

    defp admit_waiting(state) do
      if map_size(state.running) < state.max_concurrent do
        case :queue.out(state.waiting) do
          {{:value, %{pid: pid, from: from, request: request, monitor: monitor}}, waiting} ->
            if Process.alive?(pid) do
              GenServer.reply(from, :ok)
              %{state | waiting: waiting} |> admit(pid, request) |> admit_waiting()
            else
              Process.demonitor(monitor, [:flush])
              %{state | waiting: waiting} |> admit_waiting()
            end

          {:empty, _waiting} ->
            state
        end
      else
        state
      end
    end

    defp remove_waiting(waiting, pid, marker) do
      waiting
      |> :queue.to_list()
      |> Enum.reject(fn request ->
        request.pid == pid and (request.monitor == marker or request.request == marker)
      end)
      |> :queue.from_list()
    end
  end
end
