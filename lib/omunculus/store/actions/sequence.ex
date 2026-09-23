defmodule Omunculus.Store.Actions.Sequence do
  @moduledoc """
  Sequence actions of spec §3.4: `continue` moves a work to the next
  workflow stage, or closes it on the last stage or when its depth has no
  workflow; `break` parks it with a comment. A `break` reopens a parent
  waiting on its children at once; closing a work reopens it once none of
  its children is left undone; either names the reopened parent as
  `parent_id` in its event. `delegate` opens a child with its title and
  goal and parks the parent on its children; unnamed, the child's agent
  is the first stage's agent or the depth's first agent. Those three
  need a work already linked to the run. `end` appends the `end` event
  that ends the run and needs only the run.
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
         :ok <- Helpers.ensure_title(:delegate, body),
         :ok <- Helpers.ensure_goal(:delegate, body),
         {:ok, parent} <- fetch_work(:delegate, conn, ctx.work_id),
         child_depth = View.work_depth(conn, parent) + 1,
         {:ok, {stage, assignee}} <-
           Helpers.tag_error(
             :delegate,
             Helpers.stage_and_assignee(ctx.config, child_depth, body["agent"])
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

  defp ensure_context(_tag, %{run_id: run_id, work_id: work_id})
       when not is_nil(run_id) and not is_nil(work_id),
       do: :ok

  defp ensure_context(tag, _ctx), do: {:error, {tag, :no_work}}

  defp ensure_body_text(_tag, %{"body" => text}) when is_binary(text) and text != "", do: :ok
  defp ensure_body_text(tag, _body), do: {:error, {tag, :no_body}}

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
      reopen_waiting_parent(conn, work, :all_done)
    end
  end

  # A child that closes wakes its waiting parent once no sibling is left
  # undone; a child that breaks wakes it at once.
  defp reopen_waiting_parent(_conn, %{parent_id: nil}, _when_to), do: {:ok, nil}

  defp reopen_waiting_parent(conn, %{parent_id: parent_id}, when_to) do
    with {:ok, parent} <- Helpers.fetch_work(conn, parent_id),
         {:ok, wake?} <- wake_parent?(conn, parent, when_to) do
      if wake? do
        with :ok <- Helpers.reopen_work(conn, parent_id), do: {:ok, parent_id}
      else
        {:ok, nil}
      end
    end
  end

  defp wake_parent?(_conn, %{waiting: "child"}, :now), do: {:ok, true}

  defp wake_parent?(conn, %{waiting: "child", id: parent_id}, :all_done) do
    with {:ok, row} <-
           Query.one(
             conn,
             "SELECT COUNT(*) AS undone FROM works WHERE parent_id = ? AND state != 'done'",
             [parent_id]
           ) do
      {:ok, row.undone == 0}
    end
  end

  defp wake_parent?(_conn, _parent, _when_to), do: {:ok, false}

  defp apply_break(conn, ctx, body, work) do
    comment_id = Id.new()

    with {:ok, parent_id} <- reopen_waiting_parent(conn, work, :now),
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
             "UPDATE works SET state = 'waiting', waiting = 'child', waiting_from = ?, updated_at = ? WHERE id = ?",
             [ctx.agent, Events.now(), parent.id]
           ) do
      {:ok, event}
    end
  end
end
