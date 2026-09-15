defmodule Omunculus.Store do
  @moduledoc """
  The project's SQLite file behind one API: functions (`view/3`, `replay/2`)
  read a cut of the tables; actions (`apply/3`) write through the rules of
  spec §8.3. Tools never touch SQL.
  """

  alias Exqlite.Sqlite3
  alias Omunculus.Store.{Actions, Query, Schema, View}

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

  defdelegate view(conn, name, id), to: View
  defdelegate replay(conn, scope), to: View
  defdelegate apply(conn, emits, ctx), to: Actions
end
