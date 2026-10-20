defmodule Omunculus.Store.Query do
  @moduledoc """
  Thin wrapper over `Exqlite.Sqlite3`. The only place in the project allowed
  to prepare and step raw SQL, always inside the connection's owner
  (`Store.Connection`). `transaction/2` runs its whole body there, between
  `BEGIN IMMEDIATE` and `COMMIT`, so what the body reads cannot change
  before it writes.
  """

  alias Exqlite.Sqlite3
  alias Omunculus.Store.Connection

  @spec all(Connection.t(), String.t(), list()) :: {:ok, [map]} | {:error, term}
  def all(conn, sql, params \\ []) do
    Connection.run(conn, fn db ->
      with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
        try do
          with :ok <- Sqlite3.bind(stmt, params),
               {:ok, columns} <- Sqlite3.columns(db, stmt),
               {:ok, rows} <- Sqlite3.fetch_all(db, stmt) do
            {:ok, Enum.map(rows, &row_to_map(columns, &1))}
          end
        after
          Sqlite3.release(db, stmt)
        end
      end
    end)
  end

  @spec one(Connection.t(), String.t(), list()) :: {:ok, map | nil} | {:error, term}
  def one(conn, sql, params \\ []) do
    with {:ok, rows} <- all(conn, sql, params) do
      {:ok, List.first(rows)}
    end
  end

  @spec exec(Connection.t(), String.t(), list()) :: :ok | {:error, term}
  def exec(conn, sql, params \\ []) do
    Connection.run(conn, fn db ->
      with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
        try do
          with :ok <- Sqlite3.bind(stmt, params) do
            step_until_done(db, stmt)
          end
        after
          Sqlite3.release(db, stmt)
        end
      end
    end)
  end

  @spec insert(Connection.t(), atom, map) :: :ok | {:error, term}
  def insert(conn, table, row) do
    columns = Map.keys(row)
    placeholders = Enum.map_join(columns, ", ", fn _ -> "?" end)

    exec(
      conn,
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      Enum.map(columns, &Map.fetch!(row, &1))
    )
  end

  @spec transaction(Connection.t(), (-> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def transaction(conn, fun) do
    Connection.run(conn, fn _db ->
      with :ok <- exec(conn, "BEGIN IMMEDIATE") do
        run(conn, fun)
      end
    end)
  end

  defp run(conn, fun) do
    case fun.() do
      {:ok, _} = ok ->
        with :ok <- exec(conn, "COMMIT"), do: ok

      {:error, _} = error ->
        exec(conn, "ROLLBACK")
        error
    end
  rescue
    error ->
      exec(conn, "ROLLBACK")
      reraise error, __STACKTRACE__
  end

  defp step_until_done(db, stmt) do
    case Sqlite3.step(db, stmt) do
      :done -> :ok
      {:row, _row} -> step_until_done(db, stmt)
      {:error, _reason} = error -> error
      :busy -> {:error, :busy}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.map(&String.to_atom/1)
    |> Enum.zip(row)
    |> Map.new()
  end
end
