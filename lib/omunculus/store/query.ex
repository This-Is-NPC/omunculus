defmodule Omunculus.Store.Query do
  @moduledoc """
  Thin wrapper over `Exqlite.Sqlite3`. The only place in the project allowed
  to prepare and step raw SQL against a connection.
  """

  alias Exqlite.Sqlite3

  @spec all(Sqlite3.db(), String.t(), list()) :: {:ok, [map]} | {:error, term}
  def all(conn, sql, params \\ []) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params),
             {:ok, columns} <- Sqlite3.columns(conn, stmt),
             {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
          {:ok, Enum.map(rows, &row_to_map(columns, &1))}
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  @spec one(Sqlite3.db(), String.t(), list()) :: {:ok, map | nil} | {:error, term}
  def one(conn, sql, params \\ []) do
    with {:ok, rows} <- all(conn, sql, params) do
      {:ok, List.first(rows)}
    end
  end

  @spec exec(Sqlite3.db(), String.t(), list()) :: :ok | {:error, term}
  def exec(conn, sql, params \\ []) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params) do
          step_until_done(conn, stmt)
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  @spec insert(Sqlite3.db(), atom, map) :: :ok | {:error, term}
  def insert(conn, table, row) do
    columns = Map.keys(row)
    placeholders = Enum.map_join(columns, ", ", fn _ -> "?" end)

    exec(
      conn,
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      Enum.map(columns, &Map.fetch!(row, &1))
    )
  end

  @spec transaction(Sqlite3.db(), (-> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def transaction(conn, fun) do
    with :ok <- exec(conn, "BEGIN IMMEDIATE") do
      run(conn, fun)
    end
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

  defp step_until_done(conn, stmt) do
    case Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _row} -> step_until_done(conn, stmt)
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
