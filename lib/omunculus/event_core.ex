defmodule Omunculus.EventCore do
  @moduledoc """
  The local authority for commands and events (docs/to-be/event-model.md).

  Every accepted envelope is validated, checked against `event_id` and
  `idempotency_key`, appended to `EVENTS` with a monotonic `sequence`, and
  committed **before** any subscriber is notified. Subscribers receive
  `{:event_core, %Envelope{}}` after commit and may be notified more than once
  for the same envelope; consumers must be idempotent.

  The process owns the single SQLite connection. Projections run their reducers
  through `transaction/2` on this same connection so an event application and
  its cursor advance commit atomically.
  """

  use GenServer

  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore.Store

  @insert_sql """
  INSERT INTO EVENTS (#{Envelope.columns() |> Enum.reject(&(&1 == :sequence)) |> Enum.join(", ")}, content_hash)
  VALUES (#{List.duplicate("?", length(Envelope.columns()) - 1 + 1) |> Enum.join(", ")})
  """

  @select_cols Envelope.columns() |> Enum.join(", ")

  # --- API -----------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Append one envelope. Returns `{:ok, envelope}` with `sequence` assigned.

  * Same `event_id` and same content: returns the stored envelope (redelivery).
  * Same `event_id`, different content: `{:error, {:event_id_conflict, id}}`.
  * Same `idempotency_key`, same content: returns the first stored envelope.
  * Same `idempotency_key`, different payload: `{:error, {:idempotency_conflict, key}}`.
  """
  def append(core, %Envelope{} = env), do: GenServer.call(core, {:append, env}, :infinity)

  def append!(core, env) do
    {:ok, stored} = append(core, env)
    stored
  end

  @doc "Ordered read of the log after `after_sequence` (0 = from the beginning)."
  def stream(core, after_sequence \\ 0, opts \\ []) do
    GenServer.call(core, {:stream, after_sequence, opts}, :infinity)
  end

  def fetch(core, event_id), do: GenServer.call(core, {:fetch, event_id}, :infinity)

  @doc "Run `fun.(conn)` inside a single transaction on the core connection."
  def transaction(core, fun) when is_function(fun, 1),
    do: GenServer.call(core, {:transaction, fun}, :infinity)

  @doc "Read-only query helper for projections, CLI output and tests."
  def query(core, sql, args \\ []), do: GenServer.call(core, {:query, sql, args}, :infinity)

  @doc """
  Subscribe the calling process (or `pid`) to post-commit notifications.
  Options: `correlation_id:` restricts delivery to one correlation.
  """
  def subscribe(core, opts \\ []) do
    {pid, opts} = Keyword.pop(opts, :pid, self())
    GenServer.call(core, {:subscribe, pid, Map.new(opts)})
  end

  def unsubscribe(core, pid \\ self()), do: GenServer.call(core, {:unsubscribe, pid})

  def path(core), do: GenServer.call(core, :path)

  # --- callbacks -------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, ":memory:")

    case Store.open(path) do
      {:ok, conn} -> {:ok, %{conn: conn, path: path, subscribers: %{}}}
      {:error, reason} -> {:stop, {:sqlite_open, reason}}
    end
  end

  @impl true
  def handle_call({:append, env}, _from, state) do
    with :ok <- Envelope.validate(env),
         {:ok, stored, fresh?} <- persist(state.conn, env) do
      if fresh?, do: notify(state.subscribers, stored)
      {:reply, {:ok, stored}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stream, after_seq, opts}, _from, state) do
    {sql, args} = stream_query(after_seq, opts)
    rows = Store.query(state.conn, sql, args)
    {:reply, Enum.map(rows, &Envelope.from_row/1), state}
  end

  def handle_call({:fetch, event_id}, _from, state) do
    case Store.one(state.conn, "SELECT #{@select_cols} FROM EVENTS WHERE event_id = ?", [event_id]) do
      nil -> {:reply, :error, state}
      row -> {:reply, {:ok, Envelope.from_row(row)}, state}
    end
  end

  def handle_call({:transaction, fun}, _from, state) do
    result =
      try do
        {:ok, Store.transaction(state.conn, fun)}
      rescue
        e -> {:error, e}
      end

    {:reply, result, state}
  end

  def handle_call({:query, sql, args}, _from, state) do
    {:reply, Store.query(state.conn, sql, args), state}
  end

  def handle_call({:subscribe, pid, filter}, _from, state) do
    ref = Process.monitor(pid)
    subs = Map.put(state.subscribers, pid, {ref, filter})
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    state =
      case Map.pop(state.subscribers, pid) do
        {nil, _} ->
          state

        {{ref, _}, subs} ->
          Process.demonitor(ref, [:flush])
          %{state | subscribers: subs}
      end

    {:reply, :ok, state}
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  @impl true
  def terminate(_reason, state), do: Store.close(state.conn)

  # --- internals -------------------------------------------------------------

  defp persist(conn, env) do
    hash = Envelope.content_hash(env)

    Store.transaction(conn, fn conn ->
      cond do
        row = by_event_id(conn, env.event_id) ->
          {stored, stored_hash} = row

          if stored_hash == hash,
            do: {:ok, stored, false},
            else: {:error, {:event_id_conflict, env.event_id}}

        row = by_idempotency_key(conn, env.idempotency_key) ->
          {stored, _stored_hash} = row

          if same_intent?(stored, env),
            do: {:ok, stored, false},
            else: {:error, {:idempotency_conflict, env.idempotency_key}}

        true ->
          args = (env |> Envelope.to_row() |> tl()) ++ [hash]
          [] = Store.query(conn, @insert_sql, args)
          sequence = Store.last_insert_rowid(conn)
          {:ok, %{env | sequence: sequence}, true}
      end
    end)
  end

  defp same_intent?(stored, env),
    do: stored.type == env.type and stored.kind == env.kind and stored.payload == env.payload

  defp by_event_id(conn, event_id) do
    case Store.one(conn, "SELECT #{@select_cols}, content_hash FROM EVENTS WHERE event_id = ?", [
           event_id
         ]) do
      nil -> nil
      row -> split_hash(row)
    end
  end

  defp by_idempotency_key(_conn, nil), do: nil

  defp by_idempotency_key(conn, key) do
    case Store.one(
           conn,
           "SELECT #{@select_cols}, content_hash FROM EVENTS WHERE idempotency_key = ?",
           [key]
         ) do
      nil -> nil
      row -> split_hash(row)
    end
  end

  defp split_hash(row) do
    {hash, cols} = List.pop_at(row, -1)
    {Envelope.from_row(cols), hash}
  end

  defp stream_query(after_seq, opts) do
    {where, args} =
      Enum.reduce(opts, {["sequence > ?"], [after_seq]}, fn
        {:correlation_id, id}, {w, a} -> {w ++ ["correlation_id = ?"], a ++ [id]}
        {:work_item_id, id}, {w, a} -> {w ++ ["work_item_id = ?"], a ++ [id]}
        {:run_id, id}, {w, a} -> {w ++ ["run_id = ?"], a ++ [id]}
        {:type, t}, {w, a} -> {w ++ ["type = ?"], a ++ [t]}
        {:limit, _}, acc -> acc
      end)

    limit = if l = opts[:limit], do: " LIMIT #{l}", else: ""

    {"SELECT #{@select_cols} FROM EVENTS WHERE #{Enum.join(where, " AND ")} ORDER BY sequence#{limit}",
     args}
  end

  defp notify(subscribers, env) do
    Enum.each(subscribers, fn {pid, {_ref, filter}} ->
      if matches?(filter, env), do: send(pid, {:event_core, env})
    end)
  end

  defp matches?(filter, env) do
    Enum.all?(filter, fn
      {:correlation_id, id} -> env.correlation_id == id
      {:work_item_id, id} -> env.work_item_id == id
      _ -> true
    end)
  end
end
