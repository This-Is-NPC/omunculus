defmodule Omunculus.Store.Actions.Sequence do
  @moduledoc """
  Sequence actions of spec §3.4: `continue` moves a work to the next
  workflow stage, or closes it on the last stage or when its depth has no
  workflow, and is refused while the work waits or a child that broke
  waits on it; `break` parks it with a
  comment, and is refused while the work waits on its children. A
  `break` reopens a parent
  waiting on its children at once; `wait` parks a root work, one no other
  work handed down, until its person's next message reopens it, with the
  report said to them as its comment, and is refused on a work below
  another, on a work not open and while a child that broke waits on it;
  `reopen` sends a child that broke back
  to work — to its agent, to another named at its depth, or, in a
  workflow, to the agent of the stage it names, its own or one before it,
  from which it goes through the stages after again — with the
  parent's instructions as its comment, and parks the parent on its
  children again, giving the work the names it lists in `grant` that its
  agent lacks and the parent could grant it on a request; `delegate` is refused while a child that broke waits on
  the parent's decision; closing or cancelling a work reopens
  it once each of its children is done or cancelled; each names
  the reopened parent as `parent_id` in its event. `delegate` opens a
  child with its title and goal and parks the parent on its children,
  also when the parent already waits on others;
  unnamed, the child's agent is the first stage's agent or the depth's
  first agent. Those three need a work already linked to the run. `end`
  appends the `end` event that ends the run and needs only the run; a
  work's own run cannot end while its work is open and nothing will run it
  again: no request of the work pending, no next stage or message due, or
  a child that broke waiting on it.
  `cancel` sets the work of the request named by `request_id`
  `cancelled`, unless it is already done or cancelled. `retire` cancels a
  child that broke and that the parent no longer wants, with the parent's
  report as its comment, in a `cancel` event; the parent goes on, or
  waits on its children again while others are not back, and with the
  broken child gone it may delegate.
  """

  alias Omunculus.{Ceiling, Config}
  alias Omunculus.Id
  alias Omunculus.Store.Actions.{Helpers, Requests}
  alias Omunculus.Store.{Events, Query, View}

  @spec continue(Omunculus.Store.Connection.t(), map) :: {:ok, map} | {:error, term}
  def continue(conn, ctx) do
    with :ok <- ensure_context(:continue, ctx),
         {:ok, work} <- fetch_work(:continue, conn, ctx.work_id),
         :ok <- ensure_open(:continue, work),
         :ok <- no_broken_child(:continue, conn, work.id),
         {:ok, next} <- next_step(conn, ctx.config, work) do
      apply_continue(conn, ctx, work, next)
    end
  end

  @spec break(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def break(conn, body, ctx) do
    with :ok <- ensure_context(:break, ctx),
         :ok <- Helpers.ensure_text(:break, body, "body"),
         {:ok, work} <- fetch_work(:break, conn, ctx.work_id),
         :ok <- Helpers.ensure_not_waiting_children(:break, work) do
      apply_break(conn, ctx, body, work)
    end
  end

  @spec wait(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def wait(conn, body, ctx) do
    with :ok <- ensure_context(:wait, ctx),
         :ok <- Helpers.ensure_text(:wait, body, "body"),
         {:ok, work} <- fetch_work(:wait, conn, ctx.work_id),
         :ok <- ensure_root(:wait, work),
         :ok <- ensure_open(:wait, work),
         :ok <- no_broken_child(:wait, conn, work.id) do
      apply_wait(conn, ctx, body, work)
    end
  end

  # Only the person moves a root work on with a message; a work below
  # another waits on the work that handed it down.
  defp ensure_root(_tag, %{parent_id: nil}), do: :ok
  defp ensure_root(tag, _work), do: {:error, {tag, :not_root}}

  @spec delegate(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def delegate(conn, body, ctx) do
    with :ok <- ensure_context(:delegate, ctx),
         :ok <- Helpers.ensure_text(:delegate, body, "title"),
         :ok <- Helpers.ensure_text(:delegate, body, "goal"),
         {:ok, parent} <- fetch_work(:delegate, conn, ctx.work_id),
         :ok <- no_broken_child(:delegate, conn, parent.id),
         child_depth = View.work_depth(conn, parent) + 1,
         {:ok, start} <-
           Helpers.tag_error(
             :delegate,
             Helpers.stage_and_assignee(ctx.config, child_depth, body["agent"], body["workflow"])
           ),
         {:ok, workspace} <-
           Helpers.tag_error(
             :delegate,
             Helpers.resolve_workspace(ctx.config, body["workspace"], parent)
           ) do
      apply_delegate(conn, ctx, body, parent, start, workspace)
    end
  end

  # A broken child calls its parent to decide: until it reopens or breaks,
  # handing out more work, handing the work on or ending the run would leave
  # the broken one parked for good.
  defp no_broken_child(tag, conn, parent_id) do
    case Query.one(
           conn,
           "SELECT id FROM works WHERE parent_id = ? AND state = 'waiting' AND waiting IS NULL LIMIT 1",
           [parent_id]
         ) do
      {:ok, nil} -> :ok
      {:ok, %{id: id}} -> {:error, {tag, {:broken_child, id}}}
      {:error, _reason} = error -> error
    end
  end

  @spec reopen(Omunculus.Store.Connection.t(), map, map) :: {:ok, [map]} | {:error, term}
  def reopen(conn, body, ctx) do
    with :ok <- ensure_context(:reopen, ctx),
         :ok <- Helpers.ensure_text(:reopen, body, "body"),
         {:ok, parent} <- fetch_work(:reopen, conn, ctx.work_id),
         {:ok, child} <- fetch_work(:reopen, conn, body["work_id"]),
         :ok <- broken_child(:reopen, child, parent),
         {:ok, {stage, assignee}} <-
           reopen_assignee(conn, ctx.config, child, body["agent"], body["stage"]),
         {:ok, grants} <- reopen_grants(conn, ctx, child, parent, assignee, body["grant"]),
         {:ok, event} <- apply_reopen(conn, ctx, body, child, parent, {stage, assignee}) do
      give_all(conn, ctx, child, assignee, grants, event)
    end
  end

  # What the parent gives with the reopen: names the agent lacks on the work
  # and the parent could grant it on a request, so never one only the person
  # grants.
  defp reopen_grants(_conn, _ctx, _child, _parent, _assignee, nil), do: {:ok, []}

  defp reopen_grants(conn, ctx, child, parent, assignee, grants) do
    names = Enum.map(grants, & &1["name"])

    with {:ok, own} <- Requests.work_ceiling(conn, ctx, child, assignee, names),
         {:ok, giver} <- Requests.work_ceiling(conn, ctx, parent, ctx.agent, names) do
      Enum.reduce_while(grants, {:ok, []}, fn %{"kind" => kind, "name" => name} = grant,
                                              {:ok, acc} ->
        case {Ceiling.classify(own, name, kind), Ceiling.classify(giver, name, kind)} do
          {"have", _giver} -> {:cont, {:ok, acc}}
          {"askable", class} when class in ~w(have askable) -> {:cont, {:ok, acc ++ [grant]}}
          {"askable", _giver} -> {:halt, {:error, {:reopen, {:cannot_grant, name}}}}
          {"sealed", _giver} -> {:halt, {:error, {:reopen, {:only_person, name}}}}
          {"blocked", _giver} -> {:halt, {:error, {:reopen, {:blocked, name}}}}
        end
      end)
    end
  end

  defp give_all(conn, ctx, child, assignee, grants, event) do
    Enum.reduce_while(grants, {:ok, [event]}, fn grant, {:ok, events} ->
      case Requests.give(conn, ctx, child, assignee, grant) do
        {:ok, given} -> {:cont, {:ok, events ++ [given]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The broken work goes back to its agent, to another the parent names at
  # that depth, or to the agent of a stage of its workflow up to its own.
  defp reopen_assignee(_conn, _config, child, nil, nil), do: {:ok, {child.stage, child.assignee}}

  defp reopen_assignee(_conn, config, child, nil, stage) when is_binary(stage) do
    with {:ok, steps} <- reopen_steps(Config.workflow(config, child.workflow)) do
      names = Enum.map(steps, & &1.name)
      at = Enum.find_index(names, &(&1 == stage))

      cond do
        is_nil(at) ->
          {:error, {:reopen, {:unknown_stage, stage}}}

        at > Enum.find_index(names, &(&1 == child.stage)) ->
          {:error, {:reopen, {:stage_ahead, stage}}}

        true ->
          {:ok, {stage, Enum.at(steps, at).agent}}
      end
    end
  end

  defp reopen_assignee(_conn, _config, _child, nil, _stage),
    do: {:error, {:reopen, {:invalid, "stage"}}}

  defp reopen_assignee(_conn, _config, %{workflow: workflow}, _agent, nil)
       when is_binary(workflow),
       do: {:error, {:reopen, :agent_with_workflow}}

  defp reopen_assignee(conn, config, child, agent, nil) do
    if List.keymember?(Config.agents_at_depth(config, View.work_depth(conn, child)), agent, 0),
      do: {:ok, {child.stage, agent}},
      else: {:error, {:reopen, {:agent_not_allowed, agent}}}
  end

  defp reopen_assignee(_conn, _config, _child, _agent, _stage),
    do: {:error, {:reopen, :agent_and_stage}}

  defp reopen_steps({:ok, steps}), do: {:ok, steps}
  defp reopen_steps(:off), do: {:error, {:reopen, :no_workflow}}
  defp reopen_steps({:error, reason}), do: {:error, {:reopen, reason}}

  # A work a parent may reopen or retire is its own child, parked by a break.
  defp broken_child(_tag, %{parent_id: parent_id, state: "waiting", waiting: nil}, %{
         id: parent_id
       }),
       do: :ok

  defp broken_child(tag, %{parent_id: parent_id}, %{id: parent_id}),
    do: {:error, {tag, :not_broken}}

  defp broken_child(tag, _child, _parent), do: {:error, {tag, :not_a_child}}

  defp apply_reopen(conn, ctx, body, child, parent, {stage, assignee}) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "reopen",
             run_id: ctx.run_id,
             work_id: child.id,
             comment_id: comment_id,
             body: Jason.encode!(%{parent_id: parent.id, stage: stage})
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{works: child.id}, body["body"], event, ctx),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'open', stage = ?, assignee = ?, updated_at = ? WHERE id = ?",
             [stage, assignee, Events.now(), child.id]
           ),
         :ok <- wait_on_children(conn, ctx, parent.id) do
      {:ok, event}
    end
  end

  @spec retire(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def retire(conn, body, ctx) do
    with :ok <- ensure_context(:retire, ctx),
         :ok <- Helpers.ensure_text(:retire, body, "body"),
         {:ok, parent} <- fetch_work(:retire, conn, ctx.work_id),
         {:ok, child} <- fetch_work(:retire, conn, body["work_id"]),
         :ok <- broken_child(:retire, child, parent) do
      apply_retire(conn, ctx, body, child, parent)
    end
  end

  # The retired child is cancelled; a parent with other children not back
  # waits on them again, as a reopen would leave it.
  defp apply_retire(conn, ctx, body, child, parent) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "cancel",
             run_id: ctx.run_id,
             work_id: child.id,
             comment_id: comment_id,
             body: Jason.encode!(%{body: body["body"], parent_id: nil})
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{works: child.id}, body["body"], event, ctx),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'cancelled', waiting_from = NULL, updated_at = ? WHERE id = ?",
             [Events.now(), child.id]
           ),
         {:ok, %{undone: undone}} <-
           Query.one(
             conn,
             "SELECT COUNT(*) AS undone FROM works WHERE parent_id = ? AND state NOT IN ('done', 'cancelled')",
             [parent.id]
           ),
         :ok <- if(undone > 0, do: wait_on_children(conn, ctx, parent.id), else: :ok) do
      {:ok, event}
    end
  end

  defp wait_on_children(conn, ctx, parent_id),
    do:
      Query.exec(
        conn,
        "UPDATE works SET state = 'waiting', waiting = 'child', waiting_from = ?, updated_at = ? WHERE id = ?",
        [ctx.agent, Events.now(), parent_id]
      )

  @spec cancel(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def cancel(conn, body, ctx) do
    with {:ok, work} <- request_work(conn, body["request_id"]),
         :ok <- ensure_unclosed(work),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'cancelled', waiting = NULL, waiting_for = NULL, waiting_from = NULL, updated_at = ? WHERE id = ?",
             [Events.now(), work.id]
           ),
         {:ok, parent_id} <- reopen_waiting_parent(conn, work, :all_done) do
      Events.append(conn, %{
        type: "cancel",
        run_id: ctx.run_id,
        request_id: body["request_id"],
        work_id: work.id,
        body: Jason.encode!(Map.put(body, "parent_id", parent_id))
      })
    end
  end

  @spec end_run(Omunculus.Store.Connection.t(), map) :: {:ok, map} | {:error, term}
  def end_run(_conn, %{run_id: nil}), do: {:error, {:end, :no_run}}

  def end_run(conn, ctx) do
    with :ok <- settled(conn, ctx) do
      Events.append(conn, %{
        type: "end",
        run_id: ctx.run_id,
        work_id: ctx.work_id,
        body: "{}"
      })
    end
  end

  # A work's own run may not end leaving its work open with nothing that
  # runs it again: no request of it pending, no run of it due since the run
  # began (a next stage, a message, a child back that woke it), so nothing
  # would ever take it up. A root work may also wait for its person's next
  # message, which its refusal says. A child that broke waits on this run, so this
  # run must decide it first.
  defp settled(_conn, %{work_id: nil}), do: :ok

  defp settled(conn, ctx) do
    case Query.one(
           conn,
           """
           SELECT works.state = 'open' AND json_extract(start.body, '$.own') AS open,
             works.parent_id IS NULL AS root,
             EXISTS (SELECT 1 FROM requests
                     WHERE requests.work_id = works.id AND requests.status IN ('pending', 'escalated'))
               OR EXISTS (SELECT 1 FROM events
                          WHERE events.sequence > start.sequence
                            AND ((events.work_id = works.id
                                  AND (events.type = 'prompt'
                                       OR (events.type = 'continue'
                                           AND json_extract(events.body, '$.to') IS NOT NULL)))
                                 OR (events.type IN ('continue', 'break', 'cancel')
                                     AND json_extract(events.body, '$.parent_id') = works.id)))
               AS held
           FROM runs
           JOIN events AS start ON start.id = runs.event_id
           JOIN works ON works.id = ?
           WHERE runs.id = ?
           """,
           [ctx.work_id, ctx.run_id]
         ) do
      {:ok, %{open: 1, held: held, root: root}} ->
        with :ok <- no_broken_child(:end, conn, ctx.work_id),
             do: if(held == 0, do: {:error, {:end, hanging(root)}}, else: :ok)

      {:ok, _settled} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp hanging(1), do: :root_open
  defp hanging(0), do: :work_open

  defp ensure_context(_tag, %{run_id: run_id, work_id: work_id})
       when not is_nil(run_id) and not is_nil(work_id),
       do: :ok

  defp ensure_context(tag, _ctx), do: {:error, {tag, :no_work}}

  defp fetch_work(tag, conn, work_id) do
    case Helpers.fetch_work(conn, work_id) do
      {:ok, nil} -> {:error, {tag, {:missing, :works, work_id}}}
      {:ok, work} -> {:ok, work}
      {:error, _reason} = error -> error
    end
  end

  defp request_work(conn, request_id) do
    with {:ok, request} <- Helpers.fetch_request(:cancel, conn, request_id) do
      case request.work_id do
        nil -> {:error, {:cancel, :no_work}}
        work_id -> fetch_work(:cancel, conn, work_id)
      end
    end
  end

  defp ensure_unclosed(%{state: state}) when state in ["done", "cancelled"],
    do: {:error, {:cancel, {:closed, state}}}

  defp ensure_unclosed(_work), do: :ok

  defp ensure_open(_tag, %{state: "open"}), do: :ok
  defp ensure_open(tag, %{state: "waiting"}), do: {:error, {tag, :waiting}}
  defp ensure_open(tag, %{state: state}), do: {:error, {tag, {:not_open, state}}}

  defp next_step(_conn, config, work) do
    case Config.workflow(config, work.workflow) do
      {:ok, steps} -> Helpers.tag_error(:continue, Config.next_step(steps, work.stage))
      :off -> {:ok, nil}
      {:error, _reason} = error -> Helpers.tag_error(:continue, error)
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

  # A child that closes or is cancelled wakes its waiting parent once no
  # sibling is left undone; a child that breaks wakes it at once.
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
             "SELECT COUNT(*) AS undone FROM works WHERE parent_id = ? AND state NOT IN ('done', 'cancelled')",
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

  defp apply_wait(conn, ctx, body, work) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "wait",
             run_id: ctx.run_id,
             work_id: work.id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{works: work.id}, body["body"], event, ctx),
         :ok <-
           Query.exec(
             conn,
             "UPDATE works SET state = 'waiting', waiting = 'message', waiting_from = ?, updated_at = ? WHERE id = ?",
             [ctx.agent, Events.now(), work.id]
           ) do
      {:ok, event}
    end
  end

  defp apply_delegate(conn, ctx, body, parent, {workflow, stage, assignee}, workspace) do
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
             conversation_id: parent.conversation_id,
             parent_id: parent.id,
             workspace: workspace,
             assignee: assignee,
             workflow: workflow,
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
