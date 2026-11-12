defmodule Omunculus.Store.Actions.Memory do
  @moduledoc """
  Memory that outlives conversations: `memory` events of two operations.
  `remember` records a `fact`, `preference`, `procedure` or `pitfall` in
  a scope: `project`, the run's `agent` or the run's `workspace`; the
  event itself is the source, with its conversation, work, run, actor and
  time. `forget` names the id of such an event and ends the entry. The
  entries are what the events say, folded in order; the store keeps
  nothing else. `entries/2` reads those a run sees: the project's, its
  agent's and its workspace's.
  """

  alias Omunculus.Store.{Events, Query}

  @scopes ~w(project agent workspace)
  @kinds ~w(fact preference procedure pitfall)

  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Writes one `memory` emit for the run in `ctx`."
  @spec write(Omunculus.Store.Connection.t(), map, map) :: {:ok, map} | {:error, term}
  def write(conn, %{"op" => "remember"} = body, %{run_id: run_id}) when not is_nil(run_id) do
    with {:ok, scope} <- member(body, "scope", @scopes),
         {:ok, kind} <- member(body, "kind", @kinds),
         {:ok, text} <- text(body),
         {:ok, key} <- key(conn, run_id, scope) do
      record = %{"op" => "remember", "scope" => scope, "kind" => kind, "text" => text}
      record = if key, do: Map.put(record, "key", key), else: record
      Events.append(conn, %{type: "memory", run_id: run_id, body: Jason.encode!(record)})
    end
  end

  def write(conn, %{"op" => "forget", "id" => id}, %{run_id: run_id}) when not is_nil(run_id) do
    with {:ok, entries} <- entries(conn, run_id) do
      if Enum.any?(entries, &(&1["id"] == id)),
        do:
          Events.append(conn, %{
            type: "memory",
            run_id: run_id,
            body: Jason.encode!(%{"op" => "forget", "id" => id})
          }),
        else: {:error, {:memory, {:unknown, id}}}
    end
  end

  def write(_conn, %{"op" => op}, %{run_id: run_id}) when not is_nil(run_id) and is_binary(op),
    do: {:error, {:memory, {:invalid, "op"}}}

  def write(_conn, _body, _ctx), do: {:error, {:memory, :no_run}}

  @doc """
  The entries a run sees, oldest first: each its `id`, `scope`, `kind`,
  `text`, the `key` of an agent or workspace scope, and its source: `at`,
  `by` (the agent, or `person`), `conversation_id`, `work_id` and `run_id`.
  """
  @spec entries(Omunculus.Store.Connection.t(), String.t()) :: {:ok, [map]} | {:error, term}
  def entries(conn, run_id) do
    with {:ok, held} <- held(conn, run_id),
         {:ok, events} <-
           Query.all(
             conn,
             "SELECT id, at, conversation_id, work_id, run_id, actor_kind, actor_id, body FROM events WHERE type = 'memory' ORDER BY sequence"
           ) do
      entries =
        events
        |> Enum.reduce(%{}, &fold/2)
        |> Map.values()
        |> Enum.filter(&visible?(&1, held))
        |> Enum.sort_by(& &1["at"])

      {:ok, entries}
    end
  end

  defp fold(event, entries) do
    case Jason.decode!(event.body) do
      %{"op" => "remember"} = body ->
        by = if event.actor_kind == "agent", do: event.actor_id, else: "person"

        source = %{
          "id" => event.id,
          "at" => event.at,
          "by" => by,
          "conversation_id" => event.conversation_id,
          "work_id" => event.work_id,
          "run_id" => event.run_id
        }

        Map.put(entries, event.id, body |> Map.delete("op") |> Map.merge(source))

      %{"op" => "forget", "id" => id} ->
        Map.delete(entries, id)
    end
  end

  defp visible?(%{"scope" => "project"}, _held), do: true
  defp visible?(%{"scope" => scope, "key" => key}, held), do: held[scope] == key

  defp member(body, field, allowed) do
    case body[field] do
      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, {:memory, {:invalid, field}}}

      _missing ->
        {:error, {:memory, {:invalid, field}}}
    end
  end

  defp text(%{"text" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, {:memory, {:invalid, "text"}}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp text(_body), do: {:error, {:memory, {:invalid, "text"}}}

  defp key(_conn, _run_id, "project"), do: {:ok, nil}

  defp key(conn, run_id, scope) do
    with {:ok, held} <- held(conn, run_id) do
      case held[scope] do
        nil -> {:error, {:memory, {:no_scope, scope}}}
        key -> {:ok, key}
      end
    end
  end

  # The agent and the workspace a run holds, the keys of those scopes.
  defp held(conn, run_id) do
    with {:ok, %{agent: agent, workspace: workspace}} <-
           Query.one(
             conn,
             "SELECT r.agent AS agent, w.workspace AS workspace FROM runs r LEFT JOIN works w ON w.id = r.work_id WHERE r.id = ?",
             [run_id]
           ) do
      {:ok, %{"agent" => agent, "workspace" => workspace}}
    end
  end
end
