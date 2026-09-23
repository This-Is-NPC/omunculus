defmodule Omunculus.Store do
  @moduledoc """
  The project's SQLite file behind one API: functions (`view/3`, `replay/2`,
  `work_depth/2`, `unended_runs/2`, `grants/2`) read a cut of the tables; the
  run cycle (`begin_run/2`, `attach_assembled/3`, `open_run/2`, `record_model/3`,
  `record_tools/4`, `close_run/2`, `break_work/3`, `request_work/4`) is written by the harness. Every emit a call and its chained
  steps produce is applied inside that call's one transaction (spec §8.1, §8.7) — tools
  never touch SQL directly.
  """

  alias Exqlite.Sqlite3
  alias Omunculus.Store.Actions.Helpers
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
  defdelegate work_depth(conn, work), to: View
  defdelegate unended_runs(conn, work_id), to: View
  defdelegate grants(conn, work), to: Helpers
  defdelegate begin_run(conn, params), to: Runs, as: :begin
  defdelegate attach_assembled(conn, run_id, body), to: Runs
  defdelegate open_run(conn, params), to: Runs, as: :open
  defdelegate record_model(conn, run_id, text), to: Runs
  defdelegate record_tools(conn, run_id, calls, ctx), to: Runs
  defdelegate close_run(conn, run_id), to: Runs, as: :close
  defdelegate break_work(conn, run, text), to: Runs
  defdelegate request_work(conn, run, body, inbox_text), to: Runs
end
