defmodule Omunculus.Store.Actions.Inbox do
  @moduledoc """
  Inbox actions of spec §3.6: `notify` appends an `INBOX` row and its
  comment on top of `EVENTS(notify)` — the run keeps going and the work
  does not wait. `inbox.read` marks `INBOX.read_at`.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Events, Query}

  @spec notify(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def notify(conn, body, ctx) do
    with :ok <- ensure_body_text(body),
         :ok <- ensure_run(ctx),
         {:ok, work_id} <- resolve_work(conn, body, ctx) do
      apply_notify(conn, body, work_id, ctx)
    end
  end

  @spec read(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def read(conn, body, ctx) do
    inbox_id = body["inbox_id"]

    with :ok <- Helpers.tag_error(:inbox_read, Helpers.ensure_exist(conn, [{:inbox, inbox_id}])),
         :ok <- mark_read(conn, inbox_id) do
      Events.append(conn, %{
        type: "inbox.read",
        inbox_id: inbox_id,
        run_id: ctx.run_id,
        body: Jason.encode!(body)
      })
    end
  end

  defp ensure_body_text(%{"body" => text}) when is_binary(text) and text != "", do: :ok
  defp ensure_body_text(_body), do: {:error, {:notify, :no_body}}

  defp ensure_run(%{run_id: run_id}) when not is_nil(run_id), do: :ok
  defp ensure_run(_ctx), do: {:error, {:notify, :no_run}}

  defp resolve_work(conn, %{"work_id" => work_id}, _ctx) when not is_nil(work_id) do
    with :ok <- Helpers.tag_error(:notify, Helpers.ensure_exist(conn, [{:works, work_id}])) do
      {:ok, work_id}
    end
  end

  defp resolve_work(_conn, _body, ctx), do: {:ok, ctx.work_id}

  defp apply_notify(conn, body, work_id, ctx) do
    inbox_id = Id.new()
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "notify",
             run_id: ctx.run_id,
             work_id: work_id,
             inbox_id: inbox_id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Query.insert(conn, :inbox, %{
             id: inbox_id,
             run_id: ctx.run_id,
             agent: ctx.agent,
             work_id: work_id,
             event_id: event.id,
             read_at: nil,
             created_at: event.at
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{inbox: inbox_id}, body["body"], event, ctx) do
      {:ok, event}
    end
  end

  defp mark_read(conn, inbox_id) do
    Query.exec(conn, "UPDATE inbox SET read_at = ? WHERE id = ? AND read_at IS NULL", [
      Events.now(),
      inbox_id
    ])
  end
end
