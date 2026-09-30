defmodule Omunculus.Store.Connection do
  @moduledoc """
  The process that owns a store's SQLite handle. `run/2` executes a
  function with the handle inside that process, one at a time: a caller
  from another process waits its turn, so the statements of a
  `Query.transaction/2` never interleave with those of another process.
  A function already running in the owner, such as a transaction's
  body, runs directly. An exception raised in the owner is raised again
  in the caller. The owner closes the handle and stops when `close/1` is
  called or when the process that opened it exits.

  Processes that `subscribe/1` receive `{:store, owner, message}` for
  each `publish/2`. `appended/1` publishes `:events` once the rows it
  announces are committed: at once outside the owner, and inside it after
  the call that wrote them, and so the transaction around them, returns.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @enforce_keys [:owner, :db]
  defstruct @enforce_keys

  @type t :: %__MODULE__{owner: pid, db: Sqlite3.db()}

  @subscribers Omunculus.Store.Subscribers
  @appended :omunculus_store_appended

  @spec open(String.t()) :: {:ok, t} | {:error, term}
  def open(path) do
    with {:ok, owner} <- GenServer.start(__MODULE__, {path, self()}) do
      {:ok, %__MODULE__{owner: owner, db: GenServer.call(owner, :db)}}
    end
  end

  @spec close(t) :: :ok
  def close(%__MODULE__{owner: owner}) do
    GenServer.stop(owner)
  catch
    :exit, _not_running -> :ok
  end

  @spec run(t, (Sqlite3.db() -> result)) :: result when result: term
  def run(%__MODULE__{owner: owner, db: db}, fun) when owner == self(), do: fun.(db)

  def run(%__MODULE__{owner: owner}, fun) do
    case GenServer.call(owner, {:run, fun}, :infinity) do
      {:ok, result} -> result
      {:caught, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @spec subscribe(t) :: :ok
  def subscribe(%__MODULE__{owner: owner}) do
    {:ok, _owner} = Registry.register(@subscribers, owner, nil)
    :ok
  end

  @spec publish(t, term) :: :ok
  def publish(%__MODULE__{owner: owner}, message) do
    Registry.dispatch(@subscribers, owner, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, {:store, owner, message}) end)
    end)
  end

  @spec appended(t) :: :ok
  def appended(%__MODULE__{owner: owner}) when owner == self() do
    Process.put(@appended, true)
    :ok
  end

  def appended(conn), do: publish(conn, :events)

  @impl true
  def init({path, opener}) do
    case Sqlite3.open(path) do
      {:ok, db} ->
        Process.monitor(opener)
        {:ok, db}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:db, _from, db), do: {:reply, db, db}

  def handle_call({:run, fun}, _from, db) do
    reply =
      try do
        {:ok, fun.(db)}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    if Process.delete(@appended), do: publish(%__MODULE__{owner: self(), db: db}, :events)
    {:reply, reply, db}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, _opener, _reason}, db), do: {:stop, :normal, db}

  @impl true
  def terminate(_reason, db), do: Sqlite3.close(db)
end
