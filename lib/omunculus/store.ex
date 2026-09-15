defmodule Omunculus.Store do
  @moduledoc """
  Opens the project's SQLite file: one connection, foreign keys enforced,
  the seven tables of spec §4 in place.
  """

  alias Exqlite.Sqlite3
  alias Omunculus.Store.{Query, Schema}

  @spec open(String.t()) :: {:ok, Sqlite3.db()} | {:error, term}
  def open(path) do
    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- Query.exec(conn, "PRAGMA foreign_keys = ON"),
         :ok <- Schema.create(conn) do
      {:ok, conn}
    end
  end

  @spec close(Sqlite3.db()) :: :ok
  def close(conn), do: Sqlite3.close(conn)
end
