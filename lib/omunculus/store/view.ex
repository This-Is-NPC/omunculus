defmodule Omunculus.Store.View do
  @moduledoc """
  Read side of the store: the five functions of spec §8.3, plus replay of
  `events` for a project, run, work, request, or inbox scope (spec §4).
  Never executes anything against the store.
  """

  alias Omunculus.Store.Query

  @comment_views %{
    "comments.work" => :work_id,
    "comments.request" => :request_id,
    "comments.inbox" => :inbox_id
  }

  @replay_columns %{run: :run_id, work: :work_id, request: :request_id, inbox: :inbox_id}

  @spec view(Exqlite.Sqlite3.db(), String.t(), String.t()) ::
          {:ok, [map] | map | nil} | {:error, {:unknown_view, String.t()}}
  def view(conn, name, id)

  def view(conn, "events.run", id), do: replay(conn, {:run, id})

  def view(conn, "work", id) do
    Query.one(conn, "SELECT * FROM works WHERE id = ?", [id])
  end

  def view(conn, name, id) when is_map_key(@comment_views, name) do
    column = Map.fetch!(@comment_views, name)

    Query.all(
      conn,
      "SELECT * FROM comments WHERE #{column} = ? ORDER BY created_at, id",
      [id]
    )
  end

  def view(_conn, name, _id), do: {:error, {:unknown_view, name}}

  @spec replay(Exqlite.Sqlite3.db(), :project | {:run | :work | :request | :inbox, String.t()}) ::
          {:ok, [map]}
  def replay(conn, scope) do
    {where, params} = replay_filter(scope)
    Query.all(conn, "SELECT * FROM events#{where} ORDER BY sequence", params)
  end

  defp replay_filter(:project), do: {"", []}

  defp replay_filter({scope, id}) do
    column = Map.fetch!(@replay_columns, scope)
    {" WHERE #{column} = ?", [id]}
  end
end
