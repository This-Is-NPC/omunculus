defmodule Omunculus.Store.Actions.Requests do
  @moduledoc """
  Participant-neutral requests and linked escalation. Request origins, answerers,
  options and escalation links are immutable. A request parks its work; escalation
  preserves the receiving work's existing wait. Replies close their request and
  return named parts transactionally through the same reply path. Grants always
  target the original requester and retain the actual answering identity.
  """

  alias Omunculus.{Ceiling, Config, Id, Participant}
  alias Omunculus.Store.Actions.{Contract, Helpers}
  alias Omunculus.Store.{Events, Query, View}
  alias Omunculus.Tool.Invoke

  @scopes ~w(agent depth stage workspace)

  def request(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:request, body, "reason"),
         :ok <- valid_destination(body),
         {:ok, options} <- options(body["options"]),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         :ok <- ensure_actor_run(run, ctx),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         :ok <- Helpers.ensure_not_waiting_children(:request, work),
         {:ok, participant} <- Participant.from_context(ctx),
         {:ok, snapshot} <- classify_options(conn, run, options),
         {:ok, arbiter, arbiter_work_id} <-
           resolve_arbiter(
             conn,
             ctx,
             run,
             work,
             options,
             for_person?(ctx, body, snapshot, options)
           ) do
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
        true
      )
    end
  end

  def escalate(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:escalate, body, "reason"),
         {:ok, participant} <- Participant.from_context(ctx),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         :ok <- ensure_actor_run(run, ctx),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, origins} <-
           origins(conn, body["origins"], participant, conversation(ctx, run, work)),
         forbidden = Enum.flat_map(origins, fn {_part, origin} -> requesters(origin) end),
         {:ok, arbiter, arbiter_work_id} <-
           resolve_arbiter(conn, ctx, run, work, %{}, false),
         :ok <- next_receiver(arbiter, participant, forbidden),
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
         :ok <- Omunculus.RequestOptions.authorize(request, body, ctx.author == "human"),
         :ok <- if(linked?, do: :ok, else: authorize_reply(request, ctx)),
         {:ok, events} <- apply_reply(conn, ctx, request, body),
         {:ok, returned} <- return_parts(conn, request, body, ctx) do
      {:ok, events ++ returned}
    end
  end

  defp valid_destination(body) do
    if body["to"] in [nil, "person"], do: :ok, else: {:error, {:request, {:invalid, "to"}}}
  end

  defp for_person?(ctx, body, snapshot, options) do
    ctx.author == "harness" or body["to"] == "person" or
      (snapshot &&
         (Enum.any?(grants(options), &(Ceiling.classify(snapshot, &1.name, &1.kind) == "sealed")) or
            Enum.any?(
              List.flatten(Map.values(options)),
              &(Ceiling.classify(snapshot, &1.name, "tool") == "sealed")
            )))
  end

  defp resolve_arbiter(conn, ctx, run, work, _options, true),
    do: human_arbiter(conn, ctx, run, work)

  defp resolve_arbiter(conn, ctx, run, work, options, _person?) do
    with {:ok, parent} <- Helpers.fetch_work(conn, work && work.parent_id),
         {:ok, arbiter} <- agent_arbiter(conn, ctx, parent, options) do
      case arbiter do
        :human -> human_arbiter(conn, ctx, run, work)
        {:agent, name, work_id} -> {:ok, Participant.agent(name), work_id}
      end
    end
  end

  defp human_arbiter(conn, ctx, run, work) do
    with {:ok, conversation} <-
           if(conversation(ctx, run, work),
             do:
               Query.one(conn, "SELECT * FROM conversations WHERE id = ?", [
                 conversation(ctx, run, work)
               ]),
             else: {:ok, nil}
           ) do
      issuer =
        (conversation && conversation.created_issuer) || (run && run.origin_issuer) ||
          Map.get(ctx, :issuer)

      subject =
        (conversation && conversation.created_subject) || (run && run.origin_subject) ||
          Map.get(ctx, :subject)

      if is_binary(issuer) and is_binary(subject),
        do: {:ok, Participant.human(issuer, subject), nil},
        else: {:error, {:request, :missing_participant}}
    end
  end

  defp next_receiver(arbiter, participant, forbidden) do
    if arbiter in [participant | forbidden], do: {:error, {:request, :no_route}}, else: :ok
  end

  defp agent_arbiter(_conn, _ctx, nil, _options), do: {:ok, :human}
  defp agent_arbiter(_conn, _ctx, %{assignee: nil}, _options), do: {:ok, :human}

  defp agent_arbiter(conn, ctx, parent, options) do
    tools = options |> Map.values() |> List.flatten() |> Enum.map(& &1.name) |> Enum.uniq()
    grants = grants(options)

    with {:ok, snapshot} <-
           work_ceiling(conn, ctx, parent, parent.assignee, tools ++ Enum.map(grants, & &1.name)) do
      if Enum.all?(tools, &(Ceiling.classify(snapshot, &1, "tool") == "have")) and
           Enum.all?(grants, &(Ceiling.classify(snapshot, &1.name, &1.kind) in ~w(have askable))),
         do: {:ok, {:agent, parent.assignee, parent.id}},
         else: {:ok, :human}
    end
  end

  defp ensure_actor_run(nil, %{author: "human"}), do: :ok
  defp ensure_actor_run(nil, _ctx), do: {:error, {:request, :no_run}}
  defp ensure_actor_run(_run, _ctx), do: :ok

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
    if grants(options) == [], do: {:ok, nil}, else: {:error, {:request, :no_requester_run}}
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
             else: {:ok, snapshot}
      end
    end
  end

  defp create(conn, ctx, run, work, participant, reason, options, arbiter, arbiter_work_id, park?) do
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

  defp authorize_reply(_request, %{author: "human"}), do: :ok

  defp authorize_reply(request, ctx) do
    if Jason.decode!(request.arbiter) == Participant.agent(ctx.agent),
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
           Query.exec(conn, "UPDATE requests SET status = 'closed' WHERE id = ?", [request.id]),
         :ok <- reopen_requester(conn, request) do
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
         {:ok, work} <- Helpers.fetch_work(conn, request.work_id),
         :ok <- grant_work(conn, work, body["name"], body["scope"]) do
      grant_event(conn, ctx, work, request.id, %{
        name: body["name"],
        kind: body["kind"],
        agent: Jason.decode!(request.requester)["agent"],
        depth: depth,
        scope: body["scope"]
      })
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
        depth: View.work_depth(conn, work),
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
    depth = if work, do: View.work_depth(conn, work), else: ctx.config.agents[agent].depth

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
