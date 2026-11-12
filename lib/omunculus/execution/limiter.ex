defmodule Omunculus.Execution.Limiter do
  @moduledoc """
  Bounds what runs at once, one pool per class: `:tool` commands,
  `:coordinator` sessions, `:run`s, and `:resident` processes kept for a run,
  which count apart so they never starve the run's own calls. The resident
  pool is `[execution] max_resident`; without it residents are not counted.
  """

  @type class :: :tool | :coordinator | :run | :resident

  @spec acquire(
          %{
            max_concurrent: pos_integer,
            max_queue: non_neg_integer,
            queue_timeout_ms: pos_integer
          },
          pid,
          class
        ) :: {:ok, reference} | {:error, :queue_full | :queue_timeout | term}
  def acquire(limits, owner, class) when class in [:tool, :coordinator, :run, :resident] do
    if unbounded?(limits, class), do: {:ok, make_ref()}, else: admit(limits, owner, class)
  end

  defp admit(limits, owner, class) do
    with {:ok, server} <- server(limits, class) do
      lease = make_ref()

      try do
        GenServer.call(server, {:acquire, owner, lease}, limits.queue_timeout_ms)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(server, {:cancel, lease})
          {:error, :queue_timeout}
      end
    end
  end

  @spec release(%{max_concurrent: pos_integer, max_queue: non_neg_integer}, reference, class) ::
          :ok
  def release(limits, lease, class) when class in [:tool, :coordinator, :run, :resident] do
    with false <- unbounded?(limits, class),
         [{server, _}] <- Registry.lookup(Omunculus.Execution.Registry, key(limits, class)) do
      GenServer.cast(server, {:release, lease})
    end

    :ok
  end

  @spec transfer(
          %{max_concurrent: pos_integer, max_queue: non_neg_integer},
          reference,
          pid,
          class
        ) ::
          :ok | {:error, :lease_missing}
  def transfer(limits, lease, owner, class)
      when class in [:tool, :coordinator, :run, :resident] do
    with false <- unbounded?(limits, class),
         [{server, _}] <- Registry.lookup(Omunculus.Execution.Registry, key(limits, class)) do
      GenServer.call(server, {:transfer, lease, owner})
    else
      true -> :ok
      [] -> {:error, :lease_missing}
    end
  end

  # A resident process is not counted without `max_resident`.
  defp unbounded?(limits, class), do: class == :resident and is_nil(limits[:max_resident])

  defp server(limits, class) do
    case Registry.lookup(Omunculus.Execution.Registry, key(limits, class)) do
      [{server, _}] ->
        {:ok, server}

      [] ->
        child = {__MODULE__.Server, {limits, class}}

        case DynamicSupervisor.start_child(Omunculus.Execution.Limiter.Supervisor, child) do
          {:ok, server} -> {:ok, server}
          {:error, {:already_started, server}} -> {:ok, server}
          {:error, reason} -> {:error, {:limiter, reason}}
        end
    end
  end

  @doc false
  def key(limits, class),
    do: {Map.get(limits, :scope), class, capacity(limits, class), limits.max_queue}

  @doc false
  def capacity(limits, class) when class in [:tool, :run], do: limits.max_concurrent
  def capacity(limits, :coordinator), do: min(limits.max_concurrent, 1)
  def capacity(limits, :resident), do: limits.max_resident

  defmodule Server do
    @moduledoc false

    use GenServer

    def start_link({limits, class}) do
      GenServer.start_link(__MODULE__, {limits, class},
        name:
          {:via, Registry,
           {Omunculus.Execution.Registry, Omunculus.Execution.Limiter.key(limits, class)}}
      )
    end

    @impl true
    def init({limits, class}) do
      {:ok,
       %{
         max_concurrent: Omunculus.Execution.Limiter.capacity(limits, class),
         max_queue: limits.max_queue,
         running: %{},
         waiting: :queue.new()
       }}
    end

    @impl true
    def handle_call({:acquire, owner, lease}, from, state) do
      cond do
        map_size(state.running) < state.max_concurrent ->
          {:reply, {:ok, lease}, admit(state, owner, lease)}

        :queue.len(state.waiting) >= state.max_queue ->
          {:reply, {:error, :queue_full}, state}

        true ->
          waiting = %{owner: owner, from: from, lease: lease, monitor: Process.monitor(owner)}
          {:noreply, %{state | waiting: :queue.in(waiting, state.waiting)}}
      end
    end

    def handle_call({:transfer, lease, owner}, _from, state) do
      case Map.fetch(state.running, lease) do
        {:ok, %{monitor: monitor} = running} ->
          Process.demonitor(monitor, [:flush])
          running = %{running | owner: owner, monitor: Process.monitor(owner)}
          {:reply, :ok, %{state | running: Map.put(state.running, lease, running)}}

        :error ->
          {:reply, {:error, :lease_missing}, state}
      end
    end

    @impl true
    def handle_cast({:release, lease}, state),
      do: {:noreply, state |> release(lease) |> admit_waiting()}

    def handle_cast({:cancel, lease}, state) do
      state =
        case Map.fetch(state.running, lease) do
          {:ok, _running} -> state |> release(lease) |> admit_waiting()
          :error -> %{state | waiting: remove_waiting(state.waiting, lease)}
        end

      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
      state =
        case Enum.find(state.running, fn {_lease, running} -> running.monitor == monitor end) do
          {lease, _running} -> state |> release(lease, false) |> admit_waiting()
          nil -> %{state | waiting: remove_waiting(state.waiting, monitor)}
        end

      {:noreply, state}
    end

    defp admit(state, owner, lease) do
      running = %{owner: owner, monitor: Process.monitor(owner)}
      %{state | running: Map.put(state.running, lease, running)}
    end

    defp release(state, lease, demonitor \\ true) do
      case Map.pop(state.running, lease) do
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
          {{:value, %{owner: owner, from: from, lease: lease, monitor: monitor}}, waiting} ->
            if Process.alive?(owner) do
              GenServer.reply(from, {:ok, lease})
              %{state | waiting: waiting} |> admit(owner, lease) |> admit_waiting()
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

    defp remove_waiting(waiting, marker) do
      waiting
      |> :queue.to_list()
      |> Enum.reject(fn request ->
        remove? = request.lease == marker or request.monitor == marker
        if remove?, do: Process.demonitor(request.monitor, [:flush])
        remove?
      end)
      |> :queue.from_list()
    end
  end
end
