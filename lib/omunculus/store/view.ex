defmodule Omunculus.Store.View do
  @moduledoc """
  Read side of the store: the five functions of spec §8.3, the `runs` and
  `prompts` rows the harness needs to assemble or continue a run, the
  unread `inbox` list with each row's earliest comment (spec §3.6), the
  unread notifications of one work (`"inbox.work"`), the comments of
  one inbox entry, oldest first (`"comments.inbox"`), the depth of a work by walking `parent_id`, plus
  replay of `events` for a project, run, work, request, or inbox scope
  (spec §4). Never executes anything against the store.
  """

  alias Omunculus.Store.Query

  @comment_views %{
    "comments.work" => :work_id,
    "comments.request" => :request_id,
    "comments.inbox" => :inbox_id
  }

  @inbox_columns """
  id, agent, work_id, created_at,
  (SELECT body FROM comments
    WHERE comments.inbox_id = inbox.id
    ORDER BY created_at, id LIMIT 1) AS body
  """

  @replay_columns %{run: :run_id, work: :work_id, request: :request_id, inbox: :inbox_id}

  @spec view(Exqlite.Sqlite3.db(), String.t(), String.t()) ::
          {:ok, [map] | map | nil} | {:error, {:unknown_view, String.t()}}
  def view(conn, name, id)

  def view(conn, "event", id), do: Query.one(conn, "SELECT * FROM events WHERE id = ?", [id])

  def view(conn, "counter", _id) do
    with {:ok, events} <-
           Query.all(conn, "SELECT body FROM events WHERE type = 'tool' ORDER BY sequence") do
      {:ok, counter_value(events)}
    end
  end

  def view(conn, "events.run", id), do: replay(conn, {:run, id})

  def view(conn, "work", id) do
    Query.one(conn, "SELECT * FROM works WHERE id = ?", [id])
  end

  def view(conn, "run", id) do
    Query.one(conn, "SELECT * FROM runs WHERE id = ?", [id])
  end

  def view(conn, "request", id) do
    Query.one(conn, "SELECT * FROM requests WHERE id = ?", [id])
  end

  def view(conn, "prompt", id) do
    Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [id])
  end

  def view(conn, "inbox", _id) do
    Query.all(conn, """
    SELECT #{@inbox_columns}
    FROM inbox
    WHERE read_at IS NULL
    ORDER BY created_at, id
    """)
  end

  def view(conn, "inbox.work", work_id) do
    Query.all(
      conn,
      """
      SELECT #{@inbox_columns}
      FROM inbox
      WHERE read_at IS NULL AND work_id = ?
      ORDER BY created_at, id
      """,
      [work_id]
    )
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

  @spec work_depth(Exqlite.Sqlite3.db(), map) :: non_neg_integer
  def work_depth(_conn, %{parent_id: nil}), do: 0

  def work_depth(conn, %{parent_id: parent_id}) do
    {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
    1 + work_depth(conn, parent)
  end

  @spec replay(Exqlite.Sqlite3.db(), :project | {:run | :work | :request | :inbox, String.t()}) ::
          {:ok, [map]}
  def replay(conn, scope) do
    {where, params} = replay_filter(scope)
    Query.all(conn, "SELECT * FROM events#{where} ORDER BY sequence", params)
  end

  defp replay_filter(:project), do: {"", []}

  defp replay_filter({:work, id}) do
    {" WHERE work_id = ? OR (work_id IS NULL AND run_id IN (SELECT id FROM runs WHERE work_id = ?))",
     [id, id]}
  end

  defp replay_filter({scope, id}) do
    column = Map.fetch!(@replay_columns, scope)
    {" WHERE #{column} = ?", [id]}
  end

  defp counter_value(events) do
    Enum.reduce(events, 0, fn %{body: body}, value ->
      case Jason.decode(body) do
        {:ok, %{"name" => "counter"}} -> value + 1
        {:ok, %{"name" => "counter_decrement"}} -> value - 1
        _ -> value
      end
    end)
  end
end
