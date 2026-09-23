defmodule Omunculus.Store do
  @moduledoc """
  The project's SQLite file behind one API: functions (`view/3`, `replay/2`,
  `work_depth/2`, `grants/2`) read a cut of the tables; the run cycle
  (`begin_run/2`, `attach_assembled/3`, `record_model/3`,
  `record_tools/4`, `close_run/2`, `unreported/5`) is written by the
  harness. Every emit a call and its chained steps produce is applied
  inside that call's one transaction (spec §8.1, §8.7) — tools never
  touch SQL directly. One process owns the connection
  (`Store.Connection`), so the transactions of concurrent runs apply one
  after another.
  """

  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Connection, Query, Runs, Schema, View}

  @spec open(String.t()) :: {:ok, Connection.t()} | {:error, term}
  def open(path) do
    with {:ok, conn} <- Connection.open(path),
         :ok <- Query.exec(conn, "PRAGMA foreign_keys = ON"),
         :ok <- Schema.create(conn) do
      {:ok, conn}
    end
  end

  @spec close(Connection.t()) :: :ok
  defdelegate close(conn), to: Connection

  defdelegate view(conn, name, id), to: View
  defdelegate replay(conn, scope), to: View
  defdelegate work_depth(conn, work), to: View
  defdelegate grants(conn, work), to: Helpers
  defdelegate begin_run(conn, params), to: Runs, as: :begin
  defdelegate attach_assembled(conn, run_id, body), to: Runs
  defdelegate record_model(conn, run_id, text), to: Runs
  defdelegate record_tools(conn, run_id, calls, ctx), to: Runs
  defdelegate close_run(conn, run_id), to: Runs, as: :close
  defdelegate unreported(conn, run, max_retries, reason_text, inbox_text), to: Runs
end
