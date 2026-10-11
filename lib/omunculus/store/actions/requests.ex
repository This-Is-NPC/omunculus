defmodule Omunculus.Store.Actions.Requests do
  @moduledoc """
  Request actions. `request` opens a request with a `reason` and named
  `options`, each a list of `{name, args}` tool calls, and parks the
  requester's work on it (`waiting = request`); a work waiting on its
  children cannot request. The names the options'
  `grant` calls give are classified against the requester's run ceiling:
  one blocked — outside the catalog, or denied to the run — refuses the
  request as an error, so a model's call that asked for it fails; options
  made only of `grant` calls whose names are all have refuse it the same
  way, saying the run has them. The
  arbiter is the human for a request the harness opened, one granting a
  sealed name or calling a tool sealed for the requester, or one that
  says it is for the person (`to = "person"`); otherwise the parent work's agent when every tool of every
  option is have for it and every granted name have or askable, else the
  human. `reply` picks one option — the human always may, an agent only
  as the request's arbiter — closes the request, comments its body on it
  and reopens the requester's work if it still waits on the request.
  `grant` gives the request's work a name or, with a `scope` and only
  from a human, the TOML layer the harness rewrites.
  """

  alias Omunculus.{Ceiling, Config, Id}
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Events, Query, View}
  alias Omunculus.Tool.Invoke

  @scopes ~w(agent depth stage workspace)

  @spec request(Omunculus.Store.Connection.t(), map, map) :: {:ok, map | nil} | {:error, term}
  def request(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:request, body, "reason"),
         :ok <-
           if(Map.get(body, "to") in [nil, "person"],
             do: :ok,
             else: {:error, {:request, {:invalid, "to"}}}
           ),
         {:ok, options} <- options(body["options"]),
         {:ok, run} <- fetch_run(conn, ctx.run_id),
         {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         :ok <- Helpers.ensure_not_waiting_children(:request, work),
         {:ok, event} <- Query.one(conn, "SELECT body FROM events WHERE id = ?", [run.event_id]) do
      snapshot = event.body |> Jason.decode!() |> Map.fetch!("ceiling")

      classified =
        Enum.map(grants(options), fn grant ->
          {grant, Ceiling.classify(snapshot, grant.name, grant.kind)}
        end)

      # An option calling a tool only the person may give is theirs to choose.
      sealed_calls? =
        options
        |> Map.values()
        |> List.flatten()
        |> Enum.any?(&(Ceiling.classify(snapshot, &1.name, "tool") == "sealed"))

      classify_request(
        conn,
        ctx,
        run,
        body["reason"],
        options,
        classified,
        sealed_calls? or for_person?(body)
      )
    end
  end

  @spec reply(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def reply(conn, body, ctx) do
    with {:ok, request} <- Helpers.fetch_request(:reply, conn, body["request_id"]),
         :ok <- ensure_open(request),
         :ok <- ensure_option(request, body["option"]),
         :ok <- Helpers.ensure_text(:reply, body, "body"),
         :ok <- authorize_reply(request, ctx) do
      apply_reply(conn, ctx, request, body)
    end
  end

  @spec grant(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def grant(conn, body, ctx) do
    with {:ok, request} <- Helpers.fetch_request(:grant, conn, body["request_id"]),
         :ok <- Helpers.ensure_text(:grant, body, "name"),
         :ok <- Helpers.ensure_text(:grant, body, "kind"),
         :ok <- ensure_scope(body["scope"], ctx),
         {:ok, depth} <- run_depth(conn, request.run_id),
         {:ok, work} <- Helpers.fetch_work(conn, request.work_id),
         :ok <- grant_work(conn, work, body["name"], body["scope"]) do
      grant_event(conn, ctx, work, request.id, %{
        name: body["name"],
        kind: body["kind"],
        agent: request.agent,
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
    depth = View.work_depth(conn, work)

    with {:ok, grants} <- Helpers.grants(conn, work) do
      workspace_name = Config.effective_workspace(ctx.config, work)

      {:ok,
       Ceiling.mount(
         ctx.config,
         %{
           agent: agent,
           depth: depth,
           grants: grants,
           stage: stage_layer(ctx.config, work),
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

  defp options(raw) when is_map(raw) and map_size(raw) > 0 do
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

  defp fetch_run(_conn, nil), do: {:error, {:request, :no_run}}

  defp fetch_run(conn, run_id) do
    case View.view(conn, "run", run_id) do
      {:ok, nil} -> {:error, {:request, {:missing, :runs, run_id}}}
      other -> other
    end
  end

  defp for_person?(%{"to" => "person"}), do: true
  defp for_person?(_body), do: false

  defp classify_request(conn, ctx, run, reason, options, classified, sealed_calls?) do
    classes = Enum.map(classified, fn {_grant, class} -> class end)

    case List.keyfind(classified, "blocked", 1) do
      {grant, "blocked"} ->
        {:error, {:request, {:blocked, grant.name}}}

      nil ->
        if access_only?(options) and Enum.all?(classes, &(&1 == "have")) do
          names = classified |> Enum.map(fn {grant, _class} -> grant.name end) |> Enum.uniq()
          {:error, {:request, {:already_have, Enum.join(names, ", ")}}}
        else
          with {:ok, arbiter} <-
                 resolve_arbiter(conn, ctx, options, sealed_calls? or "sealed" in classes) do
            open_request(conn, ctx, run, reason, options, arbiter_info(arbiter))
          end
        end
    end
  end

  defp resolve_arbiter(_conn, %{author: "harness"}, _options, _sealed?), do: {:ok, :human}
  defp resolve_arbiter(_conn, _ctx, _options, true), do: {:ok, :human}

  defp resolve_arbiter(conn, ctx, options, false) do
    with {:ok, work} <- Helpers.fetch_work(conn, ctx.work_id),
         {:ok, parent} <- Helpers.fetch_work(conn, work && work.parent_id) do
      agent_arbiter(conn, ctx, parent, options)
    end
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

  defp stage_layer(_config, %{stage: nil}), do: nil

  defp stage_layer(config, work) do
    with {:ok, steps} <- Config.workflow(config, work.workflow),
         {:ok, step} <- Config.step_at(steps, work.stage) do
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

  defp open_request(conn, ctx, run, reason, options, arbiter) do
    request_id = Id.new()
    comment_id = Id.new()
    body = Map.merge(%{reason: reason, options: options}, arbiter.body_extra)

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
             options: Jason.encode!(options),
             arbiter: arbiter.arbiter,
             status: arbiter.status,
             event_id: event.id,
             created_at: Events.now()
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{requests: request_id}, reason, event, ctx),
         :ok <- mark_waiting(conn, ctx.work_id, request_id, run.agent) do
      {:ok, event}
    end
  end

  defp mark_waiting(_conn, nil, _request_id, _agent), do: :ok

  defp mark_waiting(conn, work_id, request_id, agent) do
    Query.exec(
      conn,
      "UPDATE works SET state = 'waiting', waiting = 'request', waiting_for = ?, waiting_from = ?, updated_at = ? WHERE id = ?",
      [request_id, agent, Events.now(), work_id]
    )
  end

  defp ensure_open(%{status: status}) when status in ["waiting_human", "waiting_agent"], do: :ok
  defp ensure_open(_request), do: {:error, {:reply, :closed}}

  defp ensure_option(request, option) do
    options = Jason.decode!(request.options)

    if is_binary(option) and Map.has_key?(options, option),
      do: :ok,
      else: {:error, {:reply, {:unknown_option, option, options |> Map.keys() |> Enum.sort()}}}
  end

  defp authorize_reply(_request, %{author: "human"}), do: :ok
  defp authorize_reply(%{status: "waiting_agent", arbiter: arbiter}, %{agent: arbiter}), do: :ok
  defp authorize_reply(_request, _ctx), do: {:error, {:reply, :not_arbiter}}

  defp apply_reply(conn, ctx, request, body) do
    comment_id = Id.new()

    with {:ok, event} <-
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
             body["body"],
             event,
             ctx
           ),
         :ok <-
           Query.exec(conn, "UPDATE requests SET status = 'closed' WHERE id = ?", [request.id]),
         :ok <- reopen_requester(conn, request) do
      {:ok, event}
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
