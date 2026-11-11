defmodule Omunculus.Store.Destination do
  @moduledoc """
  Resolves who a request goes to. Without `to`, it is whoever gave the asker
  its work: the assignee of the work's parent, or, for a root work, the
  account that opened the conversation. `to` names an `[accounts]` name or an
  agent. Returns the arbiter and the arbiter's work, nil for a person or an
  agent asked outside the asker's work chain.
  """
  alias Omunculus.{Accounts, Participant}
  alias Omunculus.Store.{Query, View}

  @spec resolve(map, map, map | nil, map | nil, map, String.t() | nil, [map]) ::
          {:ok, map, String.t() | nil} | {:error, term}
  def resolve(conn, ctx, run, work, participant, to, forbidden) do
    with {:ok, identity, work_id} <- destination(conn, ctx, run, work, to) do
      cond do
        identity == participant and is_binary(to) -> {:error, {:request, {:ask_self, to}}}
        identity == participant or identity in forbidden -> {:error, {:request, :no_route}}
        true -> {:ok, identity, work_id}
      end
    end
  end

  @doc "The identity of the conversation's requester for the action of `ctx`, or nil."
  @spec requester_identity(map, map) :: map | nil
  def requester_identity(conn, ctx) do
    with {:ok, run} <- optional(conn, "run", Map.get(ctx, :run_id)),
         {:ok, work} <- optional(conn, "work", Map.get(ctx, :work_id)),
         {:ok, identity, _work_id} <- requester(conn, ctx, run, work) do
      identity
    else
      _none -> nil
    end
  end

  defp optional(_conn, _view, nil), do: {:ok, nil}
  defp optional(conn, view, id), do: View.view(conn, view, id)

  defp destination(conn, ctx, run, work, nil), do: giver(conn, ctx, run, work)

  defp destination(conn, ctx, _run, work, name) do
    case Accounts.identity(ctx.config, name) do
      {:ok, %{"kind" => "agent", "agent" => agent} = identity} ->
        with {:ok, work_id} <- ancestor(conn, work, agent) do
          spec = ctx.config.agents[agent]

          if work_id || (spec.depth == 0 and not spec.workflow_only),
            do: {:ok, identity, work_id},
            else: {:error, {:request, {:unreachable, name}}}
        end

      {:ok, identity} ->
        {:ok, identity, nil}

      :error ->
        {:error, {:request, {:unknown_account, name, Accounts.names(ctx.config)}}}
    end
  end

  # The account that gave the asker its work.
  defp giver(conn, _ctx, _run, %{parent_id: parent_id}) when is_binary(parent_id) do
    with {:ok, parent} <- View.view(conn, "work", parent_id) do
      if parent && parent.assignee,
        do: {:ok, Participant.agent(parent.assignee), parent.id},
        else: {:error, {:request, :no_route}}
    end
  end

  defp giver(conn, ctx, run, work), do: requester(conn, ctx, run, work)

  defp requester(conn, ctx, run, work) do
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
        else: {:error, {:request, :no_route}}
    end
  end

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
