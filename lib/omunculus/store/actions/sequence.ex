defmodule Omunculus.Store.Actions.Sequence do
  @moduledoc """
  Sequence actions of spec §3.4: `continue` moves a work to the next
  workflow stage or closes it on the last one, `break` parks it with a
  comment, `delegate` opens a child and parks the parent on it. Every
  action needs a work already linked to the run. `finish_work/2` is the
  harness-side counterpart of `continue`'s last stage for a work whose
  run ended with workflow off.
  """

  alias Omunculus.Config
  alias Omunculus.Id
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Events, Query, View}

  @spec continue(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def continue(conn, body, ctx) do
    with :ok <- ensure_context(:continue, ctx),
         :ok <- Helpers.ensure_no_forbidden(:continue, body),
         {:ok, work} <- fetch_work(:continue, conn, ctx.work_id),
         {:ok, steps} <- fetch_steps(:continue, ctx.config, View.work_depth(conn, work)),
         {:ok, next} <- Helpers.tag_error(:continue, Config.next_step(steps, work.stage)) do
      apply_continue(conn, ctx, work, next)
    end
  end

  @spec break(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def break(conn, body, ctx) do
    with :ok <- ensure_context(:break, ctx),
         :ok <- Helpers.ensure_no_forbidden(:break, body),
         :ok <- ensure_body_text(:break, body),
         {:ok, work} <- fetch_work(:break, conn, ctx.work_id),
         {:ok, _steps} <- fetch_steps(:break, ctx.config, View.work_depth(conn, work)) do
      apply_break(conn, ctx, body)
    end
  end

  @spec delegate(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def delegate(conn, body, ctx) do
    with :ok <- ensure_context(:delegate, ctx),
         :ok <- Helpers.ensure_no_forbidden(:delegate, body),
         :ok <- ensure_title(body),
         :ok <- ensure_body_text(:delegate, body),
         {:ok, parent} <- fetch_work(:delegate, conn, ctx.work_id),
         child_depth = View.work_depth(conn, parent) + 1,
         {:ok, {stage, assignee}} <-
           Helpers.tag_error(
             :delegate,
             Helpers.stage_and_assignee(ctx.config, child_depth, fn ->
               depth_agent(ctx.config, child_depth)
             end)
           ),
         {:ok, workspace} <-
           Helpers.tag_error(
             :delegate,
             Helpers.resolve_workspace(ctx.config, body["workspace"], parent)
           ) do
      apply_delegate(conn, ctx, body, parent, stage, assignee, workspace)
    end
  end

  @spec finish_work(Exqlite.Sqlite3.db(), String.t(), String.t()) :: {:ok, map} | {:error, term}
  def finish_work(conn, work_id, run_id) do
    Query.transaction(conn, fn ->
      with {:ok, work} <- fetch_work(:finish, conn, work_id),
           {:ok, parent_id} <- close_work(conn, work) do
        Events.append(conn, %{
          type: "work",
          run_id: run_id,
          work_id: work_id,
          body: Jason.encode!(%{state: "done", parent_id: parent_id})
        })
      end
    end)
  end

  defp ensure_context(_tag, %{run_id: run_id, work_id: work_id})
       when not is_nil(run_id) and not is_nil(work_id),
       do: :ok

  defp ensure_context(tag, _ctx), do: {:error, {tag, :no_work}}

  defp ensure_body_text(_tag, %{"body" => text}) when is_binary(text) and text != "", do: :ok
  defp ensure_body_text(tag, _body), do: {:error, {tag, :no_body}}

  defp ensure_title(%{"title" => title}) when is_binary(title) and title != "", do: :ok
  defp ensure_title(_body), do: {:error, {:delegate, :no_title}}

  defp fetch_work(tag, conn, work_id) do
    case Helpers.fetch_work(conn, work_id) do
      {:ok, nil} -> {:error, {tag, {:missing, :works, work_id}}}
      {:ok, work} -> {:ok, work}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_steps(tag, config, depth) do
    case Config.workflow_for(config, depth) do
      {:ok, steps} -> {:ok, steps}
      :off -> {:error, {tag, :workflow_off}}
    end
  end

  defp depth_agent(config, depth) do
    case Config.agent_at_depth(config, depth) do
      {:ok, {name, _agent}} -> {:ok, name}
      {:error, _reason} = error -> error
    end
  end

  defp apply_continue(conn, ctx, work, nil) do
    with {:ok, parent_id} <- close_work(conn, work) do
      Events.append(conn, %{
        type: "continue",
        run_id: ctx.run_id,
        work_id: ctx.work_id,
        body: Jason.encode!(%{from: work.stage, to: nil, parent_id: parent_id})
      })
    end
  end

  defp apply_continue(conn, ctx, work, next) do
    with :ok <-
           Query.exec(
             conn,
             "UPDATE works SET stage = ?, assignee = ?, updated_at = ? WHERE id = ?",
             [next.name, next.agent, Events.now(), work.id]
           ) do
      Events.append(conn, %{
        type: "continue",
        run_id: ctx.run_id,
        work_id: ctx.work_id,
        body: Jason.encode!(%{from: work.stage, to: next.name})
      })
    end
  end

  defp close_work(conn, work) do
    with :ok <-
           Query.exec(conn, "UPDATE works SET state = 'done', updated_at = ? WHERE id = ?", [
             Events.now(),
             work.id
           ]) do
      reopen_waiting_parent(conn, work)
    end
  end

  defp reopen_waiting_parent(_conn, %{parent_id: nil}), do: {:ok, nil}

  defp reopen_waiting_parent(conn, %{parent_id: parent_id, id: work_id}) do
    case Helpers.fetch_work(conn, parent_id) do
      {:ok, %{waiting: "child", waiting_for: ^work_id} = parent} ->
        with :ok <- Helpers.reopen_work(conn, parent.id), do: {:ok, parent_id}

      {:ok, _parent} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_break(conn, ctx, body) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "break",
             run_id: ctx.run_id,
             work_id: ctx.work_id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Helpers.insert_comment(
             conn,
             comment_id,
             %{works: ctx.work_id},
             body["body"],
             event,
             ctx
           ),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'waiting', waiting_from = ?, updated_at = ? WHERE id = ?",
             [ctx.agent, Events.now(), ctx.work_id]
           ) do
      {:ok, event}
    end
  end

  defp apply_delegate(conn, ctx, body, parent, stage, assignee, workspace) do
    child_id = Id.new()
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "delegate",
             run_id: ctx.run_id,
             work_id: child_id,
             comment_id: comment_id,
             body:
               Jason.encode!(%{title: body["title"], body: body["body"], parent_id: parent.id})
           }),
         :ok <-
           Helpers.insert_work(conn, %{
             id: child_id,
             parent_id: parent.id,
             workspace: workspace,
             assignee: assignee,
             stage: stage,
             title: body["title"],
             event_id: event.id,
             at: event.at
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{works: child_id}, body["body"], event, ctx),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'waiting', waiting = 'child', waiting_for = ?, waiting_from = ?, updated_at = ? WHERE id = ?",
             [child_id, ctx.agent, Events.now(), parent.id]
           ) do
      {:ok, event}
    end
  end
end
