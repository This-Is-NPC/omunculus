defmodule Omunculus.Store.Actions.Requests do
  @moduledoc """
  Participant-neutral requests and linked escalation. Request origins, answerers,
  options and escalation links are immutable. A request parks its work, unless it waits on its children: then the
  child wait stays, as in an escalation, and the request's answer runs the
  work's agent by name. Replies close their request and
  return named parts transactionally through the same reply path. Grants always
  target the original requester and retain the actual answering identity.
  An escalation is an ask to the escalator's own parent, by the same rule as
  any other ask, carrying its origins.
  An origin is never escalated to its requesters, nor to an agent it was
  already escalated to that answered with text alone, naming no part, without
  escalating it further.
  An agent's run opened by the answer to its request cannot ask or escalate
  with that request's reason again: the answer stands.
  """

  alias Omunculus.{Ceiling, Config, Id, Participant}
  alias Omunculus.Store.Actions.{Contract, Helpers}
  alias Omunculus.Store.{Destination, Events, Interception, Query, View}
  alias Omunculus.Tool.Invoke

  @scopes ~w(agent depth stage workspace)

  def request(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:request, body, "reason"),
         {:ok, options} <- options(body["options"]),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         :ok <- ensure_actor_run(run, ctx),
         :ok <- not_asked_again(:request, conn, run, ctx, body["reason"]),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, participant} <- Participant.from_context(ctx),
         :ok <- classify_options(conn, run, options),
         {:ok, arbiter, arbiter_work_id} <-
           Destination.resolve(conn, ctx, run, work, participant, body["to"], []),
         :pass <- Interception.hold(conn, ctx, %{"type" => "request", "body" => body}, arbiter) do
      create(
        conn,
        ctx,
        run,
        work,
        participant,
        body["reason"],
        options,
        arbiter,
        arbiter_work_id,
        not waiting_on_children?(work)
      )
    else
      {:held, event} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  def escalate(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:escalate, body, "reason"),
         {:ok, participant} <- Participant.from_context(ctx),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         :ok <- ensure_actor_run(run, ctx),
         :ok <- not_asked_again(:escalate, conn, run, ctx, body["reason"]),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, origins} <-
           origins(conn, body["origins"], participant, conversation(ctx, run, work)),
         {:ok, upstream} <- held_upstream(conn, origins),
         forbidden =
           upstream ++ Enum.flat_map(origins, fn {_part, origin} -> requesters(origin) end),
         {:ok, arbiter, arbiter_work_id} <-
           Destination.resolve(conn, ctx, run, work, participant, body["to"], forbidden),
         {:ok, request} <-
           create(
             conn,
             ctx,
             run,
             work,
             participant,
             body["reason"],
             %{},
             arbiter,
             arbiter_work_id,
             false
           ),
         {:ok, event} <-
           Events.append(conn, %{
             type: "escalate",
             run_id: ctx.run_id,
             work_id: ctx.work_id,
             conversation_id: conversation(ctx, run, work),
             request_id: request.request_id,
             body: Jason.encode!(%{origins: body["origins"]})
           }),
         :ok <- link_origins(conn, origins, request.request_id, event.id) do
      {:ok, [request, event]}
    end
  end

  def reply(conn, body, ctx), do: reply(conn, body, ctx, false)

  defp reply(conn, body, ctx, linked?) do
    with :ok <- Contract.validate(%{"type" => "reply", "body" => body}),
         {:ok, request} <- Helpers.fetch_request(:reply, conn, body["request_id"]),
         :ok <- Omunculus.RequestOptions.validate(request, body, linked?),
         :ok <- Helpers.ensure_text(:reply, body, "body"),
         {:ok, body} <- reply_attachments(body, ctx),
         :ok <- Interception.validate_reply(request, body),
         :ok <- Omunculus.RequestOptions.authorize(request, body, ctx.author == "human"),
         :ok <- if(linked?, do: :ok, else: authorize_reply(request, ctx)),
         {:ok, events} <- apply_reply(conn, ctx, request, body),
         {:ok, returned} <- return_parts(conn, request, body, ctx),
         {:ok, settled} <- Interception.settle(conn, ctx, request, body),
         :ok <- reopen_requester(conn, request) do
      {:ok, events ++ returned ++ settled}
    end
  end

  # An answer's files, each one `Omunculus.Attachments` keeps, as a message's.
  defp reply_attachments(%{"attachments" => [_ | _] = list} = body, ctx) do
    with {:ok, checked} <- Omunculus.Attachments.check(ctx.config.store, list),
         do: {:ok, Map.put(body, "attachments", checked)}
  end

  defp reply_attachments(body, _ctx), do: {:ok, Map.delete(body, "attachments")}

  defp ensure_actor_run(nil, %{author: "human"}), do: :ok
  defp ensure_actor_run(nil, _ctx), do: {:error, {:request, :no_run}}
  defp ensure_actor_run(_run, _ctx), do: :ok

  # An agent's run opened by the answer to its question does not put that
  # very question again: the answer stands, whether it decided or only said
  # that a decision comes later.
  defp not_asked_again(tag, conn, %{request_id: request_id}, %{author: "agent"}, reason)
       when is_binary(request_id) do
    case View.view(conn, "request", request_id) do
      {:ok, %{status: "closed", reason: asked}} when is_binary(asked) ->
        if String.trim(asked) == String.trim(reason),
          do: {:error, {tag, :asked_again}},
          else: :ok

      {:ok, _other} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp not_asked_again(_tag, _conn, _run, _ctx, _reason), do: :ok

  defp fetch_run(_conn, nil), do: {:ok, nil}

  defp fetch_run(conn, id) do
    case View.view(conn, "run", id) do
      {:ok, nil} -> {:error, {:request, {:missing, :runs, id}}}
      other -> other
    end
  end

  defp conversation(ctx, run, work),
    do:
      (run && run.conversation_id) || (work && work.conversation_id) ||
        Map.get(ctx, :conversation_id)

  defp classify_options(_conn, nil, options) do
    if grants(options) == [], do: :ok, else: {:error, {:request, :no_requester_run}}
  end

  defp classify_options(conn, run, options) do
    with {:ok, event} <- View.view(conn, "event", run.event_id) do
      snapshot = Jason.decode!(event.body)["ceiling"]
      classified = Enum.map(grants(options), &{&1, Ceiling.classify(snapshot, &1.name, &1.kind)})

      case List.keyfind(classified, "blocked", 1) do
        {grant, "blocked"} ->
          {:error, {:request, {:blocked, grant.name}}}

        nil ->
          if access_only?(options) and
               Enum.all?(classified, fn {_grant, class} -> class == "have" end),
             do:
               {:error,
                {:request,
                 {:already_have,
                  classified
                  |> Enum.map(fn {grant, _} -> grant.name end)
                  |> Enum.uniq()
                  |> Enum.join(", ")}}},
             else: :ok
      end
    end
  end

  @doc """
  Opens a request from `participant` to `arbiter`, with `extra` fields in
  the event's body, and parks the work on it when `park?`.
  """
  def create(
        conn,
        ctx,
        run,
        work,
        participant,
        reason,
        options,
        arbiter,
        arbiter_work_id,
        park?,
        extra \\ %{}
      ) do
    request_id = Id.new()
    comment_id = Id.new()

    body = %{
      reason: reason,
      options: options,
      requester: participant,
      arbiter: arbiter,
      arbiter_work_id: arbiter_work_id,
      workflow: work && work.workflow,
      stage: work && work.stage
    }

    body = Map.merge(body, extra)

    with {:ok, event} <-
           Events.append(conn, %{
             type: "request",
             run_id: ctx.run_id,
             work_id: ctx.work_id,
             conversation_id: conversation(ctx, run, work),
             request_id: request_id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Query.insert(conn, :requests, %{
             id: request_id,
             run_id: ctx.run_id,
             requester: Jason.encode!(participant),
             work_id: ctx.work_id,
             options: Jason.encode!(options),
             arbiter: Jason.encode!(arbiter),
             status: "pending",
             event_id: event.id,
             created_at: event.at
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{requests: request_id}, reason, event, ctx),
         :ok <-
           if(park?,
             do: mark_waiting(conn, ctx.work_id, request_id, Participant.label(participant)),
             else: :ok
           ) do
      {:ok, event}
    end
  end

  @doc false
  def waiting_on_children?(%{state: "waiting", waiting: "child"}), do: true
  def waiting_on_children?(_work), do: false

  defp mark_waiting(_conn, nil, _request_id, _participant), do: :ok

  defp mark_waiting(conn, id, request_id, participant),
    do:
      Query.exec(
        conn,
        "UPDATE works SET state = 'waiting', waiting = 'request', waiting_for = ?, waiting_from = ?, updated_at = ? WHERE id = ?",
        [request_id, participant, Events.now(), id]
      )

  defp origins(conn, raw, participant, conversation_id) when is_map(raw) and map_size(raw) > 0 do
    if Enum.all?(raw, fn {part, id} ->
         is_binary(part) and part != "" and is_binary(id) and id != ""
       end) and
         Enum.uniq(Map.values(raw)) == Map.values(raw) do
      Enum.reduce_while(raw, {:ok, []}, fn {part, id}, {:ok, acc} ->
        with {:ok, origin} <- Helpers.fetch_request(:escalate, conn, id),
             true <- origin.status == "pending",
             true <- Jason.decode!(origin.arbiter) == participant,
             true <- origin.conversation_id == conversation_id do
          {:cont, {:ok, [{part, origin} | acc]}}
        else
          false -> {:halt, {:error, {:escalate, :invalid_origin}}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, {:escalate, :invalid_origins}}
    end
  end

  defp origins(_conn, _raw, _participant, _conversation),
    do: {:error, {:escalate, :invalid_origins}}

  defp requesters(request),
    do: [
      Jason.decode!(request.requester)
      | Enum.flat_map(request.origins, fn {_part, origin} -> requesters(origin) end)
    ]

  # The agents an origin was escalated to, however many links up, that
  # answered it with text alone, no part named, without escalating it
  # further. A reply naming parts leaves the rest for another round.
  defp held_upstream(conn, origins) do
    ids = Enum.map(origins, fn {_part, origin} -> origin.id end)

    with {:ok, rows} <-
           Query.all(
             conn,
             """
             WITH RECURSIVE up(id) AS (
               SELECT escalated_id FROM request_escalations
               WHERE origin_id IN (#{Query.placeholders(ids)})
               UNION
               SELECT e.escalated_id FROM request_escalations e JOIN up ON e.origin_id = up.id)
             SELECT requests.arbiter FROM requests JOIN up ON requests.id = up.id
             WHERE requests.status = 'closed'
               AND json_extract(requests.arbiter, '$.kind') = 'agent'
               AND NOT EXISTS (
                 SELECT 1 FROM request_escalations WHERE origin_id = requests.id)
               AND EXISTS (
                 SELECT 1 FROM events
                 WHERE events.request_id = requests.id AND events.type = 'reply'
                   AND coalesce(json_extract(events.body, '$.parts'), '{}') = '{}')
             """,
             ids
           ),
         do: {:ok, Enum.map(rows, &Jason.decode!(&1.arbiter))}
  end

  defp link_origins(conn, origins, upstream, event_id) do
    Enum.reduce_while(origins, :ok, fn {part, request}, :ok ->
      with :ok <-
             Query.insert(conn, :request_escalations, %{
               origin_id: request.id,
               escalated_id: upstream,
               part: part,
               event_id: event_id
             }),
           :ok <-
             Query.exec(conn, "UPDATE requests SET status = 'escalated' WHERE id = ?", [
               request.id
             ]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp authorize_reply(request, ctx) do
    answerer =
      case ctx do
        %{author: "human"} -> Participant.from_context(ctx)
        _agent -> {:ok, Participant.agent(ctx.agent)}
      end

    if {:ok, Jason.decode!(request.arbiter)} == answerer,
      do: :ok,
      else: {:error, {:reply, :not_arbiter}}
  end

  defp apply_reply(conn, ctx, request, body) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "reply",
             run_id: ctx.run_id,
             request_id: request.id,
             work_id: request.work_id,
             conversation_id: request.conversation_id,
             comment_id: comment_id,
             body: Jason.encode!(body)
           }),
         :ok <-
           Helpers.insert_comment(
             conn,
             comment_id,
             %{requests: request.id},
             body["body"],
             event,
             ctx
           ),
         :ok <-
           Query.exec(conn, "UPDATE requests SET status = 'closed' WHERE id = ?", [request.id]) do
      {:ok, [event]}
    end
  end

  defp return_parts(conn, request, body, ctx) do
    parts = Map.get(body, "parts", %{})

    Enum.reduce_while(request.origins, {:ok, []}, fn {part, origin}, {:ok, events} ->
      case Map.fetch(parts, part) do
        {:ok, answer} ->
          case reply(conn, Map.put(answer, "request_id", origin.id), ctx, true) do
            {:ok, replies} -> {:cont, {:ok, events ++ replies}}
            error -> {:halt, error}
          end

        :error ->
          case Query.exec(
                 conn,
                 "UPDATE requests SET status = 'pending' WHERE id = ? AND status = 'escalated'",
                 [origin.id]
               ) do
            :ok -> {:cont, {:ok, events}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp authorize_grant(_conn, _request, _body, %{author: "human"}), do: :ok

  defp authorize_grant(conn, request, body, ctx) do
    with true <- is_binary(request.requester_ceiling),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, ceiling} <- work_ceiling(conn, ctx, work, ctx.agent, [body["name"]]) do
      original =
        Ceiling.classify(Jason.decode!(request.requester_ceiling), body["name"], body["kind"])

      if original in ~w(have askable) and
           Ceiling.classify(ceiling, body["name"], body["kind"]) in ~w(have askable),
         do: :ok,
         else: {:error, {:grant, :not_authorized}}
    else
      false -> {:error, {:grant, :not_authorized}}
      error -> error
    end
  end

  @spec grant(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def grant(conn, body, ctx) do
    with {:ok, request} <- Helpers.fetch_request(:grant, conn, body["request_id"]),
         :ok <- Helpers.ensure_text(:grant, body, "name"),
         :ok <- Helpers.ensure_text(:grant, body, "kind"),
         :ok <- ensure_scope(body["scope"], ctx),
         {:ok, depth} <- run_depth(conn, request.run_id),
         :ok <- authorize_grant(conn, request, body, ctx),
         :pass <-
           Interception.hold(
             conn,
             ctx,
             %{"type" => "grant", "body" => body},
             Jason.decode!(request.requester)
           ),
         {:ok, work} <- Helpers.fetch_work(conn, request.work_id),
         :ok <- grant_work(conn, work, body["name"], body["scope"]) do
      grant_event(conn, ctx, work, request.id, %{
        name: body["name"],
        kind: body["kind"],
        agent: Jason.decode!(request.requester)["agent"],
        depth: depth,
        scope: body["scope"]
      })
    else
      {:held, event} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Gives `work` a name (`%{"kind", "name"}`) for its `agent`, outside any
  request, and records the `grant`.
  """
  @spec give(Omunculus.Store.Connection.t(), map, map, String.t(), map) ::
          {:ok, map} | {:error, term}
  def give(conn, ctx, work, agent, %{"kind" => kind, "name" => name}) do
    with :ok <- append_grant(conn, work, name) do
      grant_event(conn, ctx, work, nil, %{
        name: name,
        kind: kind,
        agent: agent,
        depth: Config.placed_depth(ctx.config, View.work_depth(conn, work), work.assignee),
        scope: nil
      })
    end
  end

  defp grant_event(conn, ctx, work, request_id, fields) do
    Events.append(conn, %{
      type: "grant",
      run_id: ctx.run_id,
      request_id: request_id,
      work_id: work && work.id,
      body:
        Jason.encode!(
          Map.merge(fields, %{
            workflow: work && work.workflow,
            stage: work && work.stage,
            workspace: work && work.workspace
          })
        )
    })
  end

  @doc """
  The ceiling `agent` has on `work`, mounted for `names`: what a grant on
  that work is checked against.
  """
  @spec work_ceiling(Omunculus.Store.Connection.t(), map, map, String.t(), [String.t()]) ::
          {:ok, map} | {:error, term}
  def work_ceiling(conn, ctx, work, agent, names) do
    depth =
      if work,
        do: Config.placed_depth(ctx.config, View.work_depth(conn, work), work.assignee),
        else: ctx.config.agents[agent].depth

    with {:ok, grants} <- Helpers.grants(conn, work) do
      workspace_name = Config.effective_workspace(ctx.config, work)

      {:ok,
       Ceiling.mount(
         ctx.config,
         %{
           agent: agent,
           depth: depth,
           grants: grants,
           stage: if(work, do: stage_layer(ctx.config, work), else: nil),
           workspace: Config.workspace_ceiling(ctx.config, workspace_name),
           groups: ctx.groups
         },
         names
       )}
    end
  end

  @doc "The scopes a permanent `grant` may name, each a TOML layer."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  defp options(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, calls}, {:ok, acc} ->
      case option_calls(name, calls) do
        {:ok, steps} -> {:cont, {:ok, Map.put(acc, name, steps)}}
        :error -> {:halt, {:error, {:request, {:invalid, :options}}}}
      end
    end)
  end

  defp options(_raw), do: {:error, {:request, {:invalid, :options}}}

  defp option_calls(name, calls) when is_binary(name) and name != "" do
    with {:ok, steps} <- Invoke.chain_steps(calls) do
      if Enum.all?(steps, &valid_call?/1), do: {:ok, steps}, else: :error
    end
  end

  defp option_calls(_name, _calls), do: :error

  defp valid_call?(%{name: "grant", args: args}),
    do: Enum.all?(~w(name kind), &(is_binary(args[&1]) and args[&1] != ""))

  defp valid_call?(_call), do: true

  defp grants(options) do
    for {_option, calls} <- options,
        %{name: "grant", args: args} <- calls,
        do: %{name: args["name"], kind: args["kind"]}
  end

  defp access_only?(options) do
    calls = options |> Map.values() |> List.flatten()
    calls != [] and Enum.all?(calls, &(&1.name == "grant"))
  end

  defp stage_layer(_config, %{stage: nil}), do: nil

  defp stage_layer(config, work) do
    with {:ok, steps} <- Config.workflow(config, work.workflow),
         {:ok, step} <- Config.step_at(steps, work.stage) do
      step.ceiling
    else
      _off_or_off_sequence -> nil
    end
  end

  defp reopen_requester(conn, request) do
    case Helpers.fetch_work(conn, request.work_id) do
      {:ok, %{state: "waiting", waiting: "request", waiting_for: id}} when id == request.id ->
        Helpers.reopen_work(conn, request.work_id)

      {:ok, _not_waiting_on_it} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_scope(nil, _ctx), do: :ok
  defp ensure_scope(scope, %{author: "human"}) when scope in @scopes, do: :ok
  defp ensure_scope(scope, _ctx) when scope in @scopes, do: {:error, {:grant, :not_human}}
  defp ensure_scope(_scope, _ctx), do: {:error, {:grant, {:invalid, :scope}}}

  defp run_depth(_conn, nil), do: {:error, {:grant, :no_requester_run}}

  defp run_depth(conn, run_id) do
    with {:ok, run} <- Query.one(conn, "SELECT depth FROM runs WHERE id = ?", [run_id]) do
      {:ok, String.to_integer(run.depth)}
    end
  end

  defp grant_work(_conn, nil, _name, _scope), do: :ok
  defp grant_work(conn, work, name, nil), do: append_grant(conn, work, name)
  defp grant_work(_conn, _work, _name, _scope), do: :ok

  defp append_grant(conn, work, name) do
    grants = if work.grants, do: Jason.decode!(work.grants), else: []
    updated = if name in grants, do: grants, else: grants ++ [name]

    Query.exec(conn, "UPDATE works SET grants = ? WHERE id = ?", [Jason.encode!(updated), work.id])
  end
end
