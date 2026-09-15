defmodule Omunculus.Store.Actions do
  @moduledoc """
  Write side of the store: `apply/3` runs the emits from a tool's `out.emit`
  as one transaction — the whole batch commits or nothing does (spec §8.3).
  """

  alias Omunculus.Id
  alias Omunculus.Store.Query

  @catalogue ~w(
    comment request notify prompt inbox.read reply work delegate continue
    break compact comment.delete
  )

  @comment_targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}

  @spec apply(Exqlite.Sqlite3.db(), [map], map) :: {:ok, [map]} | {:error, term}
  def apply(conn, emits, ctx) do
    Query.transaction(conn, fn ->
      emits
      |> Enum.reduce_while({:ok, []}, fn emit, {:ok, events} ->
        case dispatch(conn, emit, ctx) do
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        error -> error
      end
    end)
  end

  defp dispatch(conn, %{"type" => "comment"} = emit, ctx),
    do: comment(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(_conn, %{"type" => type}, _ctx) when type in @catalogue,
    do: {:error, {:not_yet, type}}

  defp dispatch(_conn, %{"type" => type}, _ctx), do: {:error, {:unknown_action, type}}

  defp comment(conn, body, ctx) do
    targets =
      Map.new(@comment_targets, fn {key, table} -> {table, Map.get(body, key)} end)

    with :ok <- ensure_text(body),
         :ok <- ensure_target(targets),
         :ok <- ensure_targets_exist(conn, targets) do
      write_comment(conn, body, targets, ctx)
    end
  end

  defp ensure_text(%{"body" => text}) when is_binary(text) and text != "", do: :ok
  defp ensure_text(_body), do: {:error, {:comment, :no_body}}

  defp ensure_target(targets) do
    if Enum.any?(targets, fn {_table, id} -> not is_nil(id) end) do
      :ok
    else
      {:error, {:comment, :no_target}}
    end
  end

  defp ensure_targets_exist(conn, targets) do
    targets
    |> Enum.reject(fn {_table, id} -> is_nil(id) end)
    |> Enum.reduce_while(:ok, fn {table, id}, :ok ->
      case Query.one(conn, "SELECT id FROM #{table} WHERE id = ?", [id]) do
        {:ok, nil} -> {:halt, {:error, {:comment, {:missing, table, id}}}}
        {:ok, _row} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_comment(conn, body, targets, ctx) do
    comment_id = Id.new()

    with {:ok, event} <-
           append_event(conn, %{
             type: "comment",
             comment_id: comment_id,
             run_id: ctx.run_id,
             work_id: targets.works,
             request_id: targets.requests,
             inbox_id: targets.inbox,
             body: Jason.encode!(body)
           }),
         :ok <-
           Query.insert(conn, :comments, %{
             id: comment_id,
             work_id: targets.works,
             request_id: targets.requests,
             inbox_id: targets.inbox,
             run_id: ctx.run_id,
             event_id: event.id,
             author: ctx.author,
             kind: "note",
             body: body["body"],
             created_at: now()
           }) do
      {:ok, event}
    end
  end

  defp append_event(conn, fields) do
    id = Id.new()

    with {:ok, %{max: max}} <-
           Query.one(conn, "SELECT COALESCE(MAX(sequence), 0) AS max FROM events"),
         :ok <-
           Query.insert(conn, :events, Map.merge(fields, %{id: id, sequence: max + 1, at: now()})) do
      Query.one(conn, "SELECT * FROM events WHERE id = ?", [id])
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
