defmodule Omunculus.Store.View do
  @moduledoc """
  Read side of the store. `view/3` reads one row the harness and the store
  need by id: an `event`, `work`, `run`, `request` or `prompt`. The named
  functions read the cuts a tool's views are composed from
  (`Omunculus.Tool.Views`): a work's children, parent and comments, the
  comments of a request or an inbox entry, a work's last closed run and
  the run that opened a request — each with the message that opened it and
  every event it recorded — the events of a run, the most recent run, the
  unread inbox of the project or of a work, and the bench counter. Also how
  many of a work's latest closed runs in a row lack `end`, the depth of a
  work by walking `parent_id`, whether a work descends from another, and
  replay of `events` for a project, run, work, request, inbox or
  conversation scope. Never executes anything against the store.
  """

  alias Omunculus.Store.Query

  @comment_columns %{work: :work_id, request: :request_id, inbox: :inbox_id}

  @inbox_columns """
  id, agent, work_id, created_at,
  (SELECT body FROM comments
    WHERE comments.inbox_id = inbox.id
    ORDER BY created_at, id LIMIT 1) AS body
  """

  @closed_runs """
  FROM runs JOIN events AS start ON start.id = runs.event_id
  WHERE runs.work_id = ? AND runs.status = 'done'
  """

  @replay_columns %{run: :run_id, work: :work_id, request: :request_id, inbox: :inbox_id}

  @spec view(Omunculus.Store.Connection.t(), String.t(), String.t()) ::
          {:ok, map | nil} | {:error, {:unknown_view, String.t()}}
  def view(conn, name, id)

  def view(conn, "event", id), do: Query.one(conn, "SELECT * FROM events WHERE id = ?", [id])
  def view(conn, "work", id), do: Query.one(conn, "SELECT * FROM works WHERE id = ?", [id])
  def view(conn, "run", id), do: Query.one(conn, "SELECT * FROM runs WHERE id = ?", [id])

  def view(conn, "request", id),
    do: Query.one(conn, "SELECT * FROM requests WHERE id = ?", [id])

  def view(conn, "prompt", id), do: Query.one(conn, "SELECT * FROM prompts WHERE id = ?", [id])
  def view(_conn, name, _id), do: {:error, {:unknown_view, name}}

  @doc """
  The children of a work, oldest first: only those in `states` when given,
  and, with `since_last_run`, only those changed after the work's last
  closed run finished.
  """
  @spec children(Omunculus.Store.Connection.t(), String.t(), [String.t()] | nil, boolean) ::
          {:ok, [map]}
  def children(conn, work_id, states, since_last_run) do
    {state_filter, state_params} =
      case states do
        nil -> {"", []}
        states -> {" AND state IN (#{Enum.map_join(states, ", ", fn _ -> "?" end)})", states}
      end

    with {:ok, since} <- since(conn, work_id, since_last_run) do
      {since_filter, since_params} =
        if since, do: {" AND updated_at > ?", [since]}, else: {"", []}

      Query.all(
        conn,
        "SELECT * FROM works WHERE parent_id = ?#{state_filter}#{since_filter} ORDER BY created_at, id",
        [work_id | state_params] ++ since_params
      )
    end
  end

  defp since(_conn, _work_id, false), do: {:ok, nil}

  defp since(conn, work_id, true) do
    with {:ok, run} <-
           Query.one(
             conn,
             "SELECT runs.finished_at #{@closed_runs} ORDER BY start.sequence DESC LIMIT 1",
             [work_id]
           ) do
      {:ok, run && run.finished_at}
    end
  end

  @doc "The comments of a work, request or inbox entry, oldest first."
  @spec comments(Omunculus.Store.Connection.t(), :work | :request | :inbox, String.t()) ::
          {:ok, [map]}
  def comments(conn, target, id) do
    column = Map.fetch!(@comment_columns, target)
    Query.all(conn, "SELECT * FROM comments WHERE #{column} = ? ORDER BY created_at, id", [id])
  end

  @doc "The last closed run of a work, with its record."
  @spec last_closed_run(Omunculus.Store.Connection.t(), String.t()) :: {:ok, map | nil}
  def last_closed_run(conn, work_id) do
    with {:ok, run} <-
           Query.one(
             conn,
             "SELECT runs.* #{@closed_runs} ORDER BY start.sequence DESC LIMIT 1",
             [work_id]
           ) do
      with_record(conn, run)
    end
  end

  @doc "The closed runs of a work, oldest first, each with its record."
  @spec closed_runs(Omunculus.Store.Connection.t(), String.t()) :: {:ok, [map]}
  def closed_runs(conn, work_id) do
    with {:ok, runs} <-
           Query.all(conn, "SELECT runs.* #{@closed_runs} ORDER BY start.sequence", [work_id]) do
      Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
        case with_record(conn, run) do
          {:ok, recorded} -> {:cont, {:ok, acc ++ [recorded]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "The run that opened a request, with its record."
  @spec opener_run(Omunculus.Store.Connection.t(), String.t()) :: {:ok, map | nil}
  def opener_run(conn, request_id) do
    with {:ok, run} <-
           Query.one(
             conn,
             "SELECT runs.* FROM runs JOIN requests ON requests.run_id = runs.id WHERE requests.id = ?",
             [request_id]
           ) do
      with_record(conn, run)
    end
  end

  @doc "The most recently started run."
  @spec latest_run(Omunculus.Store.Connection.t()) :: {:ok, map | nil}
  def latest_run(conn),
    do: Query.one(conn, "SELECT * FROM runs ORDER BY started_at DESC, id DESC LIMIT 1")

  @doc "The unread inbox, of the project or of one work, each entry with its first comment."
  @spec unread_inbox(Omunculus.Store.Connection.t(), String.t() | nil) :: {:ok, [map]}
  def unread_inbox(conn, nil) do
    Query.all(conn, """
    SELECT #{@inbox_columns}
    FROM inbox
    WHERE read_at IS NULL
    ORDER BY created_at, id
    """)
  end

  def unread_inbox(conn, work_id) do
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

  @doc "The bench counter: `counter` calls minus `counter_decrement` calls."
  @spec counter(Omunculus.Store.Connection.t()) :: {:ok, integer}
  def counter(conn) do
    with {:ok, events} <-
           Query.all(conn, "SELECT body FROM events WHERE type = 'tool' ORDER BY sequence") do
      {:ok, counter_value(events)}
    end
  end

  @spec work_depth(Omunculus.Store.Connection.t(), map) :: non_neg_integer
  def work_depth(_conn, %{parent_id: nil}), do: 0

  def work_depth(conn, %{parent_id: parent_id}) do
    {:ok, parent} = Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id])
    1 + work_depth(conn, parent)
  end

  @doc "Whether `work_id` is below `ancestor_id`, at any depth."
  @spec descends?(Omunculus.Store.Connection.t(), String.t(), String.t()) :: boolean
  def descends?(conn, work_id, ancestor_id) do
    case Query.one(conn, "SELECT parent_id FROM works WHERE id = ?", [work_id]) do
      {:ok, %{parent_id: ^ancestor_id}} -> true
      {:ok, %{parent_id: nil}} -> false
      {:ok, %{parent_id: parent_id}} -> descends?(conn, parent_id, ancestor_id)
      {:ok, nil} -> false
    end
  end

  @doc "The number of the most recent closed runs of a work, in a row, without `end`."
  @spec unended_runs(Omunculus.Store.Connection.t(), String.t()) :: non_neg_integer
  def unended_runs(conn, work_id) do
    {:ok, runs} =
      Query.all(
        conn,
        """
        SELECT EXISTS (SELECT 1 FROM events
          WHERE events.run_id = runs.id AND events.type = 'end') AS ended
        #{@closed_runs}
        ORDER BY start.sequence DESC
        """,
        [work_id]
      )

    Enum.count(Enum.take_while(runs, &(&1.ended == 0)))
  end

  @spec replay(
          Omunculus.Store.Connection.t(),
          :project | {:run | :work | :request | :inbox | :conversation, String.t()}
        ) ::
          {:ok, [map]}
  def replay(conn, scope) do
    {where, params} = replay_filter(scope)
    Query.all(conn, "SELECT * FROM events#{where} ORDER BY sequence", params)
  end

  defp replay_filter(:project), do: {"", []}

  defp replay_filter({:conversation, id}), do: {" WHERE conversation_id = ?", [id]}

  defp replay_filter({:work, id}) do
    {" WHERE work_id = ? OR (work_id IS NULL AND run_id IN (SELECT id FROM runs WHERE work_id = ?))",
     [id, id]}
  end

  defp replay_filter({scope, id}) do
    column = Map.fetch!(@replay_columns, scope)
    {" WHERE #{column} = ?", [id]}
  end

  defp with_record(_conn, nil), do: {:ok, nil}

  defp with_record(conn, run) do
    with {:ok, message} <-
           Query.one(conn, "SELECT * FROM prompts WHERE run_id = ? AND kind = 'message'", [run.id]),
         {:ok, events} <- replay(conn, {:run, run.id}) do
      {:ok, Map.merge(run, %{message: message, events: events})}
    end
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
