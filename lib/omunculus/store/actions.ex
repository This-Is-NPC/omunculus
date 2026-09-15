defmodule Omunculus.Store.Actions do
  @moduledoc """
  Write side of the store: `run/3` applies the emits from a tool's
  `out.emit` in order, inside whatever transaction the caller holds — the
  whole batch commits or nothing does (spec §8.3).
  """

  alias Omunculus.Id
  alias Omunculus.Store.{Events, Query}

  @catalogue ~w(
    comment request notify inbox.read reply delegate continue
    break compact comment.delete
  )

  @comment_targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}

  @spec run(Exqlite.Sqlite3.db(), [map], map) :: {:ok, [map]} | {:error, term}
  def run(conn, emits, ctx) do
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
  end

  defp dispatch(conn, %{"type" => "comment"} = emit, ctx),
    do: comment(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "prompt"} = emit, _ctx),
    do: prompt(conn, Map.get(emit, "body", %{}))

  defp dispatch(conn, %{"type" => "work"} = emit, ctx),
    do: work(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(_conn, %{"type" => type}, _ctx) when type in @catalogue,
    do: {:error, {:not_yet, type}}

  defp dispatch(_conn, %{"type" => type}, _ctx), do: {:error, {:unknown_action, type}}

  defp comment(conn, body, ctx) do
    targets =
      Map.new(@comment_targets, fn {key, table} -> {table, Map.get(body, key)} end)

    with :ok <- ensure_text(body),
         :ok <- ensure_target(targets),
         :ok <- tag_error(:comment, ensure_exist(conn, Map.to_list(targets))) do
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

  defp ensure_exist(conn, targets) do
    targets
    |> Enum.reject(fn {_table, id} -> is_nil(id) end)
    |> Enum.reduce_while(:ok, fn {table, id}, :ok ->
      case Query.one(conn, "SELECT id FROM #{table} WHERE id = ?", [id]) do
        {:ok, nil} -> {:halt, {:error, {:missing, table, id}}}
        {:ok, _row} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp tag_error(tag, {:error, {:missing, _table, _id} = reason}), do: {:error, {tag, reason}}
  defp tag_error(_tag, other), do: other

  defp write_comment(conn, body, targets, ctx) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
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
             created_at: Events.now()
           }) do
      {:ok, event}
    end
  end

  defp prompt(conn, %{"message" => text} = body) when is_binary(text) and text != "" do
    with :ok <- tag_error(:prompt, ensure_exist(conn, [{:works, body["work_id"]}])) do
      write_prompt(conn, body, text)
    end
  end

  defp prompt(_conn, _body), do: {:error, {:prompt, :no_message}}

  defp write_prompt(conn, body, text) do
    prompt_id = Id.new()

    with :ok <-
           Query.insert(conn, :prompts, %{
             id: prompt_id,
             kind: "message",
             body: text,
             run_id: nil,
             created_at: Events.now()
           }) do
      Events.append(conn, %{
        type: "prompt",
        prompt_id: prompt_id,
        work_id: body["work_id"],
        body: Jason.encode!(body)
      })
    end
  end

  defp work(conn, %{"title" => title} = body, ctx) when is_binary(title) and title != "" do
    case body["work_id"] do
      nil -> create_work(conn, body, ctx)
      work_id -> update_work(conn, work_id, body, ctx)
    end
  end

  defp work(_conn, _body, _ctx), do: {:error, {:work, :no_title}}

  defp update_work(conn, work_id, body, ctx) do
    with :ok <- tag_error(:work, ensure_exist(conn, [{:works, work_id}])),
         :ok <-
           Query.exec(conn, "UPDATE works SET title = ?, updated_at = ? WHERE id = ?", [
             body["title"],
             Events.now(),
             work_id
           ]) do
      Events.append(conn, %{
        type: "work",
        work_id: work_id,
        run_id: ctx.run_id,
        body: Jason.encode!(body)
      })
    end
  end

  defp create_work(conn, body, ctx) do
    with :ok <- tag_error(:work, ensure_exist(conn, [{:works, body["parent_id"]}])) do
      work_id = Id.new()
      now = Events.now()

      with {:ok, event} <-
             Events.append(conn, %{
               type: "work",
               work_id: work_id,
               run_id: ctx.run_id,
               body: Jason.encode!(body)
             }),
           :ok <-
             Query.insert(conn, :works, %{
               id: work_id,
               parent_id: body["parent_id"],
               event_id: event.id,
               assignee: ctx.agent,
               title: body["title"],
               state: "open",
               created_at: now,
               updated_at: now
             }),
           :ok <- link_run(conn, ctx.run_id, work_id) do
        {:ok, event}
      end
    end
  end

  defp link_run(_conn, nil, _work_id), do: :ok

  defp link_run(conn, run_id, work_id) do
    case Query.one(conn, "SELECT work_id FROM runs WHERE id = ?", [run_id]) do
      {:ok, %{work_id: nil}} ->
        Query.exec(conn, "UPDATE runs SET work_id = ? WHERE id = ?", [work_id, run_id])

      {:ok, _row} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
