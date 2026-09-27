defmodule Omunculus.Server.StreamLimiter do
  @moduledoc "Bounds the number of open event streams in one server."

  use GenServer

  def start_link({key, maximum}) do
    GenServer.start_link(__MODULE__, maximum,
      name: {:via, Registry, {Omunculus.Server.Registry, {:stream_limiter, key}}}
    )
  end

  def acquire(key), do: GenServer.call(via(key), {:acquire, self()})
  def release(key), do: GenServer.call(via(key), {:release, self()})

  defp via(key), do: {:via, Registry, {Omunculus.Server.Registry, {:stream_limiter, key}}}

  @impl true
  def init(maximum), do: {:ok, %{maximum: maximum, members: %{}}}

  @impl true
  def handle_call({:acquire, pid}, _from, state) do
    cond do
      Map.has_key?(state.members, pid) ->
        {:reply, :ok, state}

      map_size(state.members) >= state.maximum ->
        {:reply, {:error, :too_many_streams}, state}

      true ->
        monitor = Process.monitor(pid)
        {:reply, :ok, %{state | members: Map.put(state.members, pid, monitor)}}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    {monitor, members} = Map.pop(state.members, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | members: members}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    members =
      case Map.get(state.members, pid) do
        ^monitor -> Map.delete(state.members, pid)
        _ -> state.members
      end

    {:noreply, %{state | members: members}}
  end
end
