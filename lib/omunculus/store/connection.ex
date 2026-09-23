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
  """

  use GenServer

  alias Exqlite.Sqlite3

  @enforce_keys [:owner, :db]
  defstruct @enforce_keys

  @type t :: %__MODULE__{owner: pid, db: Sqlite3.db()}

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

    {:reply, reply, db}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, _opener, _reason}, db), do: {:stop, :normal, db}

  @impl true
  def terminate(_reason, db), do: Sqlite3.close(db)
end
