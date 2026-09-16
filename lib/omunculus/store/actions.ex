defmodule Omunculus.Store.Actions do
  @moduledoc """
  Write side of the store: `run/3` applies the emits from a tool's
  `out.emit` in order, inside whatever transaction the caller holds — the
  whole batch commits or nothing does (spec §8.3). `continue`, `break`
  and `delegate` are dispatched to `Actions.Sequence`; `notify` and
  `inbox.read` to `Actions.Inbox`; `compact` and `comment.delete` to
  `Actions.Comments`.
  """

  alias Omunculus.Ceiling
  alias Omunculus.Config
  alias Omunculus.Id
  alias Omunculus.Store.Actions.{Comments, Helpers, Inbox, Sequence}
  alias Omunculus.Store.{Events, Query, View}

  @comment_targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}
  @request_kinds ~w(tool path directory)
  @reply_decisions ~w(grant deny)
  @reply_scopes ~w(agent depth)

  @spec run(Exqlite.Sqlite3.db(), [map], map) :: {:ok, [map]} | {:error, term}
  def run(conn, emits, ctx) do
    emits
    |> Enum.reduce_while({:ok, []}, fn emit, {:ok, events} ->
      case dispatch(conn, emit, ctx) do
        {:ok, result} -> {:cont, {:ok, [result | events]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, events |> Enum.reverse() |> List.flatten() |> Enum.reject(&is_nil/1)}
      error -> error
    end
  end

  defp dispatch(conn, %{"type" => "comment"} = emit, ctx),
    do: comment(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "prompt"} = emit, _ctx),
    do: prompt(conn, Map.get(emit, "body", %{}))

  defp dispatch(conn, %{"type" => "work"} = emit, ctx),
    do: work(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "request"} = emit, ctx),
    do: request(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "reply"} = emit, ctx),
    do: reply(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "continue"} = emit, ctx),
    do: Sequence.continue(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "break"} = emit, ctx),
    do: Sequence.break(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "delegate"} = emit, ctx),
    do: Sequence.delegate(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "notify"} = emit, ctx),
    do: Inbox.notify(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "inbox.read"} = emit, ctx),
    do: Inbox.read(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "compact"} = emit, ctx),
    do: Comments.compact(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "comment.delete"} = emit, ctx),
    do: Comments.delete(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(_conn, %{"type" => type}, _ctx), do: {:error, {:unknown_action, type}}

  defp comment(conn, body, ctx) do
    targets =
      Map.new(@comment_targets, fn {key, table} -> {table, Map.get(body, key)} end)

    with :ok <- ensure_text(body),
         :ok <- ensure_target(targets),
         :ok <- Helpers.tag_error(:comment, Helpers.ensure_exist(conn, Map.to_list(targets))) do
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
         :ok <- Helpers.insert_comment(conn, comment_id, targets, body["body"], event, ctx) do
      {:ok, event}
    end
  end

  defp prompt(conn, %{"message" => text} = body) when is_binary(text) and text != "" do
    with :ok <-
           Helpers.tag_error(:prompt, Helpers.ensure_exist(conn, [{:works, body["work_id"]}])) do
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
    with :ok <- Helpers.ensure_no_forbidden(:work, body) do
      case body["work_id"] do
        nil -> create_work(conn, body, ctx)
        work_id -> update_work(conn, work_id, body, ctx)
      end
    end
  end

  defp work(_conn, _body, _ctx), do: {:error, {:work, :no_title}}

  defp update_work(conn, work_id, body, ctx) do
    with :ok <- Helpers.tag_error(:work, Helpers.ensure_exist(conn, [{:works, work_id}])),
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
    with {:ok, depth} <- Helpers.tag_error(:work, Helpers.depth_at(conn, body["parent_id"])),
         {:ok, {stage, assignee}} <-
           Helpers.stage_and_assignee(ctx.config, depth, fn -> {:ok, ctx.agent} end) do
      work_id = Id.new()

      with {:ok, event} <-
             Events.append(conn, %{
               type: "work",
               work_id: work_id,
               run_id: ctx.run_id,
               body: Jason.encode!(body)
             }),
           :ok <-
             Helpers.insert_work(conn, %{
               id: work_id,
               parent_id: body["parent_id"],
               assignee: assignee,
               stage: stage,
               title: body["title"],
               event_id: event.id,
               at: event.at
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

  defp request(conn, body, ctx) do
    kind = body["kind"]
    name = body["name"]
    reason = body["reason"]

    with :ok <- ensure_kind(kind),
         :ok <- ensure_name(name),
         :ok <- ensure_reason(reason),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         {:ok, event} <- Query.one(conn, "SELECT * FROM events WHERE id = ?", [run.event_id]) do
      snapshot = event.body |> Jason.decode!() |> Map.fetch!("ceiling")
      classify_request(conn, ctx, run, Ceiling.classify(snapshot, name), kind, name, reason)
    end
  end

  defp ensure_kind(kind) when kind in @request_kinds, do: :ok
  defp ensure_kind(_kind), do: {:error, {:request, {:invalid, :kind}}}

  defp ensure_name(name) when is_binary(name) and name != "", do: :ok
  defp ensure_name(_name), do: {:error, {:request, :no_name}}

  defp ensure_reason(reason) when is_binary(reason) and reason != "", do: :ok
  defp ensure_reason(_reason), do: {:error, {:request, :no_reason}}

  defp fetch_run(_conn, nil), do: {:error, {:request, :no_run}}

  defp fetch_run(conn, run_id) do
    case Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id]) do
      {:ok, nil} -> {:error, {:request, {:missing, :runs, run_id}}}
      other -> other
    end
  end

  defp classify_request(_conn, _ctx, _run, "have", _kind, _name, _reason), do: {:ok, nil}

  defp classify_request(conn, ctx, _run, "blocked", kind, name, reason) do
    Events.append(conn, %{
      type: "deny",
      run_id: ctx.run_id,
      work_id: ctx.work_id,
      body: Jason.encode!(%{kind: kind, name: name, reason: reason})
    })
  end

  defp classify_request(conn, ctx, run, class, kind, name, reason)
       when class in ["askable", "sealed"] do
    open_request(conn, ctx, run, kind, name, reason)
  end

  defp open_request(conn, ctx, run, kind, name, reason) do
    with {:ok, arbiter} <- resolve_arbiter(conn, ctx, name) do
      request_id = Id.new()
      comment_id = Id.new()
      body = Map.merge(%{kind: kind, name: name, reason: reason}, arbiter.body_extra)

      with {:ok, event} <-
             Events.append(conn, %{
               type: "request",
               run_id: ctx.run_id,
               work_id: ctx.work_id,
               request_id: request_id,
               comment_id: comment_id,
               body: Jason.encode!(body)
             }),
           :ok <-
             Query.insert(conn, :requests, %{
               id: request_id,
               run_id: ctx.run_id,
               agent: run.agent,
               work_id: ctx.work_id,
               ask: Jason.encode!(%{kind: kind, name: name}),
               arbiter: arbiter.arbiter,
               status: arbiter.status,
               event_id: event.id,
               created_at: Events.now()
             }),
           :ok <-
             Helpers.insert_comment(conn, comment_id, %{requests: request_id}, reason, event, ctx),
           :ok <- mark_waiting_for_access(conn, ctx.work_id, name, run.agent) do
        {:ok, event}
      end
    end
  end

  defp resolve_arbiter(conn, ctx, name) do
    with {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, parent} <- Helpers.fetch_work(conn, work && work.parent_id),
         {:ok, decision} <- agent_arbiter(conn, ctx, parent, name) do
      {:ok, arbiter_info(decision)}
    end
  end

  defp agent_arbiter(_conn, _ctx, nil, _name), do: {:ok, :human}
  defp agent_arbiter(_conn, _ctx, %{assignee: nil}, _name), do: {:ok, :human}

  defp agent_arbiter(conn, ctx, parent, name) do
    depth = View.work_depth(conn, parent)

    with {:ok, grants} <- Helpers.grants(conn, parent) do
      stage = stage_layer(ctx.config, depth, parent.stage)

      snapshot =
        Ceiling.mount(
          ctx.config,
          %{
            agent: parent.assignee,
            depth: depth,
            grants: grants,
            stage: stage,
            groups: ctx.groups
          },
          [name]
        )

      case Ceiling.classify(snapshot, name) do
        class when class in ["have", "askable"] -> {:ok, {:agent, parent.assignee, parent.id}}
        _class -> {:ok, :human}
      end
    end
  end

  defp stage_layer(_config, _depth, nil), do: nil

  defp stage_layer(config, depth, stage) do
    with {:ok, steps} <- Config.workflow_for(config, depth),
         {:ok, step} <- Config.step_at(steps, stage) do
      step.ceiling
    else
      _off_or_off_sequence -> nil
    end
  end

  defp arbiter_info(:human), do: %{arbiter: "human", status: "waiting_human", body_extra: %{}}

  defp arbiter_info({:agent, arbiter, arbiter_work_id}),
    do: %{
      arbiter: arbiter,
      status: "waiting_agent",
      body_extra: %{arbiter: arbiter, arbiter_work_id: arbiter_work_id}
    }

  defp mark_waiting_for_access(_conn, nil, _name, _agent), do: :ok

  defp mark_waiting_for_access(conn, work_id, name, agent) do
    Query.exec(
      conn,
      "UPDATE works SET state = 'waiting', waiting = 'access', waiting_for = ?, waiting_from = ?, updated_at = ? WHERE id = ?",
      [name, agent, Events.now(), work_id]
    )
  end

  defp reply(conn, body, ctx) do
    request_id = body["request_id"]
    decision = body["decision"]
    text = body["body"]
    scope = body["scope"]

    with :ok <- Helpers.tag_error(:reply, Helpers.ensure_exist(conn, [{:requests, request_id}])),
         {:ok, request} <- Query.one(conn, "SELECT * FROM requests WHERE id = ?", [request_id]),
         :ok <- ensure_open(request),
         :ok <- ensure_decision(decision),
         :ok <- ensure_reply_text(text),
         :ok <- ensure_scope(scope) do
      apply_reply(conn, ctx, request, decision, text, scope, body)
    end
  end

  defp ensure_open(%{status: status}) when status in ["waiting_human", "waiting_agent"], do: :ok
  defp ensure_open(_request), do: {:error, {:reply, :closed}}

  defp ensure_decision(decision) when decision in @reply_decisions, do: :ok
  defp ensure_decision(_decision), do: {:error, {:reply, {:invalid, :decision}}}

  defp ensure_reply_text(text) when is_binary(text) and text != "", do: :ok
  defp ensure_reply_text(_text), do: {:error, {:reply, :no_body}}

  defp ensure_scope(nil), do: :ok
  defp ensure_scope(scope) when scope in @reply_scopes, do: :ok
  defp ensure_scope(_scope), do: {:error, {:reply, {:invalid, :scope}}}

  defp apply_reply(conn, ctx, request, decision, text, scope, body) do
    comment_id = Id.new()

    with {:ok, reply_event} <-
           Events.append(conn, %{
             type: "reply",
             run_id: ctx.run_id,
             request_id: request.id,
             work_id: request.work_id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Helpers.insert_comment(
             conn,
             comment_id,
             %{requests: request.id},
             text,
             reply_event,
             ctx
           ),
         :ok <-
           Query.exec(conn, "UPDATE requests SET status = 'closed' WHERE id = ?", [
             request.id
           ]),
         {:ok, effect_event} <- apply_decision(conn, ctx, decision, request, scope) do
      {:ok, [reply_event, effect_event]}
    end
  end

  defp apply_decision(conn, ctx, "grant", request, scope) do
    ask = Jason.decode!(request.ask)

    with {:ok, depth} <- run_depth(conn, request.run_id),
         :ok <- grant_work(conn, request.work_id, ask["name"], scope) do
      Events.append(conn, %{
        type: "grant",
        run_id: ctx.run_id,
        request_id: request.id,
        work_id: request.work_id,
        body:
          Jason.encode!(%{
            name: ask["name"],
            kind: ask["kind"],
            agent: request.agent,
            depth: depth,
            scope: scope
          })
      })
    end
  end

  defp apply_decision(conn, ctx, "deny", request, _scope) do
    ask = Jason.decode!(request.ask)

    with :ok <- Helpers.reopen_work(conn, request.work_id) do
      Events.append(conn, %{
        type: "deny",
        run_id: ctx.run_id,
        request_id: request.id,
        work_id: request.work_id,
        body: Jason.encode!(%{name: ask["name"], kind: ask["kind"]})
      })
    end
  end

  defp run_depth(conn, run_id) do
    with {:ok, run} <- Query.one(conn, "SELECT depth FROM runs WHERE id = ?", [run_id]) do
      {:ok, String.to_integer(run.depth)}
    end
  end

  defp grant_work(_conn, nil, _name, _scope), do: :ok

  defp grant_work(conn, work_id, name, nil) do
    with :ok <- append_grant(conn, work_id, name), do: Helpers.reopen_work(conn, work_id)
  end

  defp grant_work(conn, work_id, _name, _scope), do: Helpers.reopen_work(conn, work_id)

  defp append_grant(conn, work_id, name) do
    with {:ok, work} <- Query.one(conn, "SELECT grants FROM works WHERE id = ?", [work_id]) do
      grants = if work.grants, do: Jason.decode!(work.grants), else: []
      updated = if name in grants, do: grants, else: grants ++ [name]

      Query.exec(conn, "UPDATE works SET grants = ? WHERE id = ?", [
        Jason.encode!(updated),
        work_id
      ])
    end
  end
end
