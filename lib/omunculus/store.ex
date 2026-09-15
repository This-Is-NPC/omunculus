defmodule Omunculus.Store do
  @moduledoc """
  The project's SQLite file behind one API: functions (`view/3`, `replay/2`)
  read a cut of the tables; the run cycle (`open_run/2`, `record_model/3`,
  `record_tool/5`, `close_run/2`) is written by the harness. Every emit a
  call produces is applied inside that same call's transaction (spec §8.1,
  §8.7) — tools never touch SQL directly.
  """

  alias Exqlite.Sqlite3
  alias Omunculus.Store.{Query, Runs, Schema, View}

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
  defdelegate open_run(conn, params), to: Runs, as: :open
  defdelegate record_model(conn, run_id, text), to: Runs
  defdelegate record_tool(conn, run_id, call, emits, ctx), to: Runs
  defdelegate close_run(conn, run_id), to: Runs, as: :close
end
