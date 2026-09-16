defmodule Omunculus.Store.Actions.Comments do
  @moduledoc """
  `compact` and `comment.delete` of spec §8.3: both act on exactly one of
  `work_id`, `request_id` or `inbox_id` — a run inside a work may only
  target that work. `compact` replaces every comment of the target (or
  only the ones named in `ids`) with a single summary comment; `EVENTS`
  keeps the `compact` event and every `comment` event it replaced,
  `comment_id` and all, even once the row is gone. `comment.delete`
  removes named comments of the target without leaving a summary behind.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Events, Query}

  @targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}

  @spec compact(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def compact(conn, body, ctx) do
    with {:ok, {column, table, id}} <- target(:compact, conn, body, ctx),
         :ok <- ensure_summary(body),
         {:ok, all_ids} <- comment_ids(conn, column, id),
         {:ok, deleted} <- resolve_deleted(:compact, all_ids, body["ids"]) do
      apply_compact(conn, column, table, id, deleted, body["summary"], ctx)
    end
  end

  @spec delete(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def delete(conn, body, ctx) do
    with {:ok, {column, _table, id}} <- target(:comment_delete, conn, body, ctx),
         {:ok, ids} <- ensure_ids(body),
         {:ok, all_ids} <- comment_ids(conn, column, id),
         :ok <- validate_owned(:comment_delete, all_ids, ids),
         :ok <- delete_comments(conn, ids) do
      Events.append(
        conn,
        %{type: "comment.delete", run_id: ctx.run_id, body: Jason.encode!(body)}
        |> Map.put(column, id)
      )
    end
  end

  defp target(tag, conn, body, ctx) do
    with {:ok, {column, table, id}} <- pick_target(tag, body),
         :ok <- ensure_same_work(tag, table, id, ctx),
         :ok <- Helpers.tag_error(tag, Helpers.ensure_exist(conn, [{table, id}])) do
      {:ok, {column, table, id}}
    end
  end

  defp pick_target(tag, body) do
    @targets
    |> Enum.filter(fn {key, _table} -> not is_nil(body[key]) end)
    |> case do
      [] -> {:error, {tag, :no_target}}
      [{key, table}] -> {:ok, {String.to_existing_atom(key), table, body[key]}}
      [_ | _] -> {:error, {tag, :many_targets}}
    end
  end

  defp ensure_same_work(tag, :works, id, %{work_id: work_id})
       when not is_nil(work_id) and id != work_id,
       do: {:error, {tag, :foreign_work}}

  defp ensure_same_work(_tag, _table, _id, _ctx), do: :ok

  defp ensure_summary(%{"summary" => summary}) when is_binary(summary) and summary != "",
    do: :ok

  defp ensure_summary(_body), do: {:error, {:compact, :no_summary}}

  defp ensure_ids(%{"ids" => ids}) when is_list(ids) and ids != [], do: {:ok, ids}
  defp ensure_ids(_body), do: {:error, {:comment_delete, :no_ids}}

  defp comment_ids(conn, column, id) do
    sql = "SELECT id FROM comments WHERE #{column} = ? ORDER BY created_at, id"

    with {:ok, rows} <- Query.all(conn, sql, [id]) do
      {:ok, Enum.map(rows, & &1.id)}
    end
  end

  defp resolve_deleted(_tag, all_ids, nil), do: {:ok, all_ids}

  defp resolve_deleted(tag, all_ids, ids) do
    with :ok <- validate_owned(tag, all_ids, ids) do
      {:ok, Enum.filter(all_ids, &(&1 in ids))}
    end
  end

  defp validate_owned(tag, all_ids, ids) do
    case Enum.find(ids, &(&1 not in all_ids)) do
      nil -> :ok
      foreign -> {:error, {tag, {:foreign, foreign}}}
    end
  end

  defp delete_comments(_conn, []), do: :ok

  defp delete_comments(conn, ids) do
    placeholders = Enum.map_join(ids, ", ", fn _id -> "?" end)
    Query.exec(conn, "DELETE FROM comments WHERE id IN (#{placeholders})", ids)
  end

  defp apply_compact(conn, column, table, id, deleted, summary, ctx) do
    summary_id = Id.new()

    with :ok <- delete_comments(conn, deleted),
         {:ok, event} <-
           Events.append(
             conn,
             %{
               type: "compact",
               comment_id: summary_id,
               run_id: ctx.run_id,
               body: Jason.encode!(%{summary: summary, deleted: deleted})
             }
             |> Map.put(column, id)
           ),
         :ok <- Helpers.insert_comment(conn, summary_id, %{table => id}, summary, event, ctx) do
      {:ok, event}
    end
  end
end
