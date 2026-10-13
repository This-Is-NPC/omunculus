defmodule Omunculus.Server.EventStream do
  @moduledoc """
  The WebSocket of one conversation, or, without `conversation_id`, of every
  conversation of the project the principal may read: sends each event
  committed after the cursor and each partial model reply as a JSON text
  frame. It accepts no messages from the client.
  """

  @behaviour WebSock

  alias Omunculus.Server.{Contract, Project, StreamLimiter}

  @keepalive_ms 15_000

  @impl true
  def init(state) do
    case StreamLimiter.acquire(state.stream_key) do
      :ok ->
        :ok = Project.subscribe(state.project)
        Process.send_after(self(), :keepalive, @keepalive_ms)
        read(state)

      {:error, :too_many_streams} ->
        {:stop, :normal, {1013, "too_many_streams"}, state}
    end
  end

  @impl true
  def handle_in(_frame, state), do: {:stop, :normal, {1003, "unsupported"}, state}

  @impl true
  def handle_info({:store, _owner, :events}, state) do
    drain_announcements()
    read(state)
  end

  def handle_info(:read, state), do: read(state)

  # The conversations a delta may come from are those the last read could read.
  def handle_info({:store, _owner, {:delta, delta}}, state) do
    if delta.conversation_id in state.readable,
      do: {:push, {:text, Jason.encode!(Contract.delta(state.project, delta))}, state},
      else: {:ok, state}
  end

  # Reading again after a keepalive also notices a revoked membership: it
  # closes a conversation's stream and leaves the project's without it.
  def handle_info(:keepalive, state) do
    Process.send_after(self(), :keepalive, @keepalive_ms)
    send(self(), :read)
    {:push, {:ping, ""}, state}
  end

  @impl true
  def terminate(_reason, state), do: StreamLimiter.release(state.stream_key)

  defp read(state) do
    case events(state) do
      {:ok, readable, []} ->
        {:ok, %{state | readable: readable}}

      {:ok, readable, events} ->
        send(self(), :read)
        frames = Enum.map(events, &{:text, Jason.encode!(Contract.event(state.project, &1))})
        {:push, frames, %{state | cursor: List.last(events).sequence, readable: readable}}

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:stop, :normal, {1008, "forbidden"}, state}

      {:error, reason} ->
        {:stop, reason, {1011, "internal_error"}, state}
    end
  end

  defp events(%{conversation_id: nil} = state),
    do: Project.project_events(state.project, state.principal, state.cursor)

  defp events(state) do
    with {:ok, events} <-
           Project.events(state.project, state.principal, state.conversation_id, state.cursor),
         do: {:ok, [state.conversation_id], events}
  end

  defp drain_announcements do
    receive do
      {:store, _owner, :events} -> drain_announcements()
    after
      0 -> :ok
    end
  end
end
