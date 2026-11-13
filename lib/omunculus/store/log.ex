defmodule Omunculus.Store.Log do
  @moduledoc """
  The rows process mining reads: for the project's `last` conversations
  (newest first by creation; all of them without `last`), their works,
  runs, requests and the events that matter to a process — tool calls,
  model replies, stage moves, request traffic, artifacts — with only the
  fields of an event's body the log needs, and the job fires that ran in
  them. A tool's output and the content of a message stay in the store.
  """

  alias Omunculus.Store.Query

  @event_types ~w(tool model work delegate continue reopen cancel request escalate reply artifact)

  @spec read(Omunculus.Store.Connection.t(), pos_integer | nil) :: {:ok, map} | {:error, term}
  def read(conn, last) do
    scope = scope(last)

    with {:ok, conversations} <-
           Query.all(
             conn,
             "SELECT id, created_at FROM conversations c #{scope.where}",
             scope.params
           ),
         {:ok, works} <-
           Query.all(
             conn,
             """
             SELECT id, conversation_id, parent_id, title, workflow, stage, state, assignee, created_at
             FROM works WHERE conversation_id IN (SELECT id FROM conversations c #{scope.where})
             ORDER BY created_at, id
             """,
             scope.params
           ),
         {:ok, runs} <-
           Query.all(
             conn,
             """
             SELECT id, conversation_id, work_id, agent, depth, via, started_at, finished_at
             FROM runs WHERE conversation_id IN (SELECT id FROM conversations c #{scope.where})
             ORDER BY started_at, id
             """,
             scope.params
           ),
         {:ok, requests} <-
           Query.all(
             conn,
             """
             SELECT requests.id, requests.run_id, requests.work_id, requests.status,
                    requests.created_at, events.conversation_id
             FROM requests JOIN events ON events.id = requests.event_id
             WHERE events.conversation_id IN (SELECT id FROM conversations c #{scope.where})
             ORDER BY requests.created_at, requests.id
             """,
             scope.params
           ),
         {:ok, events} <- events(conn, scope),
         {:ok, fires} <- fires(conn, scope) do
      {:ok,
       %{
         conversations: conversations,
         works: works,
         runs: runs,
         requests: requests,
         events: events,
         fires: fires
       }}
    end
  end

  # Fields come out of a body only where it is JSON: a model reply may be text.
  defp events(conn, scope) do
    Query.all(
      conn,
      """
      SELECT id, sequence, type, at, conversation_id, run_id, work_id, request_id,
             CASE WHEN type = 'model' THEN body END AS body,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.name') END AS name,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.ok') END AS ok,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.from') END AS from_stage,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.to') END AS to_stage,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.stage') END AS stage,
             CASE WHEN type = 'model' THEN NULL ELSE json_extract(body, '$.kind') END AS kind
      FROM events
      WHERE conversation_id IN (SELECT id FROM conversations c #{scope.where})
        AND type IN (#{Enum.map_join(@event_types, ", ", &"'#{&1}'")})
      ORDER BY sequence
      """,
      scope.params
    )
  end

  defp fires(conn, scope) do
    Query.all(
      conn,
      """
      SELECT id, at, sequence, json_extract(body, '$.id') AS job_id,
             json_extract(body, '$.state') AS state,
             json_extract(body, '$.conversation_id') AS conversation_id,
             json_extract(body, '$.run_ids') AS run_ids,
             json_extract(body, '$.usd') AS usd
      FROM events
      WHERE type = 'job_fire'
        AND json_extract(body, '$.conversation_id') IN (SELECT id FROM conversations c #{scope.where})
      ORDER BY sequence
      """,
      scope.params
    )
  end

  defp scope(nil), do: %{where: "", params: []}

  defp scope(last),
    do: %{where: "ORDER BY c.created_at DESC, c.id DESC LIMIT ?", params: [last]}
end
