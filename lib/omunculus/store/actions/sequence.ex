defmodule Omunculus.Store.Actions.Sequence do
  @moduledoc """
  Sequence actions of spec §3.4: `continue` moves a work to the next
  workflow stage, or closes it on the last stage or when its depth has no
  workflow; `break` parks it with a comment; both reopen a parent waiting
  on the work and name it as `parent_id` in their event. `delegate` opens
  a child with its title and goal and parks the parent on it. Those three
  need a work already linked to the run. `end` appends the `end` event
  that ends the run and needs only the run.
  `finish_work/3` is the harness-side counterpart of `continue`'s last
  stage for a work still open after its model stopped without `end`, with
  workflow off.
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
         :ok <- ensure_open(:continue, work),
         {:ok, next} <- next_step(conn, ctx.config, work) do
      apply_continue(conn, ctx, work, next)
    end
  end

  @spec break(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def break(conn, body, ctx) do
    with :ok <- ensure_context(:break, ctx),
         :ok <- Helpers.ensure_no_forbidden(:break, body),
         :ok <- ensure_body_text(:break, body),
         {:ok, work} <- fetch_work(:break, conn, ctx.work_id) do
      apply_break(conn, ctx, body, work)
    end
  end

  @spec delegate(Exqlite.Sqlite3.db(), map, map) :: {:ok, map} | {:error, term}
  def delegate(conn, body, ctx) do
    with :ok <- ensure_context(:delegate, ctx),
         :ok <- Helpers.ensure_no_forbidden(:delegate, body),
         :ok <- ensure_title(body),
         :ok <- Helpers.ensure_goal(:delegate, body),
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

  @spec end_run(Exqlite.Sqlite3.db(), map) :: {:ok, map} | {:error, term}
  def end_run(_conn, %{run_id: nil}), do: {:error, {:end, :no_run}}

  def end_run(conn, ctx) do
    Events.append(conn, %{
      type: "end",
      run_id: ctx.run_id,
      work_id: ctx.work_id,
      body: "{}"
    })
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

  defp ensure_open(_tag, %{state: "open"}), do: :ok
  defp ensure_open(tag, %{state: "waiting"}), do: {:error, {tag, :waiting}}
  defp ensure_open(tag, %{state: state}), do: {:error, {tag, {:not_open, state}}}

  defp next_step(conn, config, work) do
    case Config.workflow_for(config, View.work_depth(conn, work)) do
      {:ok, steps} -> Helpers.tag_error(:continue, Config.next_step(steps, work.stage))
      :off -> {:ok, nil}
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

  defp apply_break(conn, ctx, body, work) do
    comment_id = Id.new()

    with {:ok, parent_id} <- reopen_waiting_parent(conn, work),
         {:ok, event} <-
           Events.append(conn, %{
             type: "break",
             run_id: ctx.run_id,
             work_id: ctx.work_id,
             comment_id: comment_id,
             body: Jason.encode!(Map.put(body, "parent_id", parent_id))
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

    with {:ok, event} <-
           Events.append(conn, %{
             type: "delegate",
             run_id: ctx.run_id,
             work_id: child_id,
             body:
               Jason.encode!(%{title: body["title"], goal: body["goal"], parent_id: parent.id})
           }),
         :ok <-
           Helpers.insert_work(conn, %{
             id: child_id,
             parent_id: parent.id,
             workspace: workspace,
             assignee: assignee,
             stage: stage,
             title: body["title"],
             goal: body["goal"],
             event_id: event.id,
             at: event.at
           }),
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
