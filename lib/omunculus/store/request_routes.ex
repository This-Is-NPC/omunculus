defmodule Omunculus.Store.RequestRoutes do
  @moduledoc "Resolves TOML request destinations from authenticated origins and work ancestry."
  alias Omunculus.Participant
  alias Omunculus.Store.{Query, View}

  def resolve(conn, ctx, run, work, participant, name, forbidden) do
    routes = Enum.filter(ctx.config.request_routes, &(&1["name"] == name))

    if not is_nil(name) and routes == [] do
      names =
        ctx.config.request_routes
        |> Enum.map(& &1["name"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:error, {:request, {:unknown_route, name, names}}}
    else
      resolve_routes(conn, ctx, run, work, participant, forbidden, routes)
    end
  end

  defp resolve_routes(conn, ctx, run, work, participant, forbidden, routes) do
    rule =
      Enum.find(routes, fn rule ->
        (is_nil(rule["from"]) or rule["from"] == participant) and
          (is_nil(rule["workflow"]) or (work && work.workflow) == rule["workflow"]) and
          (is_nil(rule["stage"]) or (work && work.stage) == rule["stage"])
      end)

    destinations = if rule, do: rule["via"], else: []

    Enum.reduce_while(destinations, {:error, {:request, :no_route}}, fn destination, _error ->
      with {:ok, identity, work_id} <- destination(conn, destination, ctx, run, work),
           false <- identity in [participant | forbidden] do
        {:halt, {:ok, identity, work_id}}
      else
        {:error, reason} when reason != :absent -> {:halt, {:error, reason}}
        _missing_or_cycle -> {:cont, {:error, {:request, :no_route}}}
      end
    end)
  end

  defp destination(_conn, "parent", _ctx, _run, nil), do: {:error, :absent}
  defp destination(_conn, "parent", _ctx, _run, %{parent_id: nil}), do: {:error, :absent}

  defp destination(conn, "parent", _ctx, _run, work) do
    with {:ok, parent} <- View.view(conn, "work", work.parent_id) do
      if parent && parent.assignee,
        do: {:ok, Participant.agent(parent.assignee), parent.id},
        else: {:error, :absent}
    end
  end

  defp destination(conn, "origin", ctx, run, work) do
    conversation_id =
      (run && run.conversation_id) || (work && work.conversation_id) ||
        Map.get(ctx, :conversation_id)

    with {:ok, conversation} <- conversation(conn, conversation_id) do
      issuer =
        (conversation && conversation.created_issuer) || (run && run.origin_issuer) ||
          Map.get(ctx, :origin_issuer) || Map.get(ctx, :issuer)

      subject =
        (conversation && conversation.created_subject) || (run && run.origin_subject) ||
          Map.get(ctx, :origin_subject) || Map.get(ctx, :subject)

      if is_binary(issuer) and is_binary(subject),
        do: {:ok, Participant.human(issuer, subject), nil},
        else: {:error, :absent}
    end
  end

  defp destination(conn, %{"kind" => "agent", "agent" => agent} = identity, ctx, _run, work) do
    with {:ok, work_id} <- ancestor(conn, work, agent) do
      spec = ctx.config.agents[agent]

      if work_id || (spec.depth == 0 and not spec.workflow_only),
        do: {:ok, identity, work_id},
        else: {:error, :absent}
    end
  end

  defp destination(_conn, %{"kind" => "human"} = identity, _ctx, _run, _work),
    do: {:ok, identity, nil}

  defp ancestor(_conn, nil, _agent), do: {:ok, nil}
  defp ancestor(_conn, %{assignee: agent, id: id}, agent), do: {:ok, id}
  defp ancestor(_conn, %{parent_id: nil}, _agent), do: {:ok, nil}

  defp ancestor(conn, work, agent) do
    with {:ok, parent} <- View.view(conn, "work", work.parent_id),
         do: ancestor(conn, parent, agent)
  end

  defp conversation(_conn, nil), do: {:ok, nil}

  defp conversation(conn, id),
    do: Query.one(conn, "SELECT * FROM conversations WHERE id = ?", [id])
end
