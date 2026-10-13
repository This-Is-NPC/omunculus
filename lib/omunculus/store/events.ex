defmodule Omunculus.Store.Events do
  @moduledoc """
  Appends rows to `events`, the spine of the store: `sequence` is
  assigned as `MAX(sequence) + 1`, `id` is a fresh `Omunculus.Id`, `at` is
  the current UTC time.
  """

  alias Omunculus.Id
  alias Omunculus.Store.{Connection, Query, View}

  @actor_key :omunculus_event_actor

  @spec with_actor(Connection.t(), map, (-> result)) :: result when result: term
  def with_actor(conn, ctx, fun) do
    Connection.run(conn, fn _db ->
      previous = Process.get(@actor_key)

      Process.put(
        @actor_key,
        Map.take(ctx, [:author, :agent, :issuer, :subject, :origin_issuer, :origin_subject])
      )

      try do
        fun.()
      after
        if previous, do: Process.put(@actor_key, previous), else: Process.delete(@actor_key)
      end
    end)
  end

  # The whole append runs in the connection's owner, so no other append
  # takes the same sequence between reading the last one and inserting.
  @spec append(Omunculus.Store.Connection.t(), map) :: {:ok, map} | {:error, term}
  def append(conn, fields), do: Connection.run(conn, fn _db -> insert(conn, fields) end)

  defp insert(conn, fields) do
    actor = Process.get(@actor_key, %{})

    fields =
      fields
      |> Map.put_new(:actor_kind, Map.get(actor, :author))
      |> Map.put_new(:actor_id, Map.get(actor, :agent))
      |> Map.put_new(:actor_issuer, Map.get(actor, :issuer))
      |> Map.put_new(:actor_subject, Map.get(actor, :subject))
      |> Map.put_new(:origin_issuer, Map.get(actor, :origin_issuer) || Map.get(actor, :issuer))
      |> Map.put_new(:origin_subject, Map.get(actor, :origin_subject) || Map.get(actor, :subject))
      |> run_context(conn)
      |> conversation_context(conn)

    id = Id.new()

    with {:ok, %{max: max}} <-
           Query.one(conn, "SELECT COALESCE(MAX(sequence), 0) AS max FROM events"),
         :ok <-
           Query.insert(conn, :events, Map.merge(fields, %{id: id, sequence: max + 1, at: now()})),
         :ok <- Connection.appended(conn) do
      View.view(conn, "event", id)
    end
  end

  defp run_context(%{run_id: run_id} = fields, conn) when not is_nil(run_id) do
    case Query.one(
           conn,
           "SELECT r.work_id, r.request_id, r.conversation_id, r.origin_issuer, r.origin_subject, r.agent AS actor_id, e.inbox_id FROM runs r LEFT JOIN events e ON e.id = r.event_id WHERE r.id = ?",
           [run_id]
         ) do
      {:ok, context} when is_map(context) ->
        Enum.reduce(context, fields, fn {key, value}, acc ->
          if is_nil(Map.get(acc, key)), do: Map.put(acc, key, value), else: acc
        end)

      _ ->
        fields
    end
  end

  defp run_context(fields, _conn), do: fields

  defp conversation_context(%{conversation_id: id} = fields, _conn) when not is_nil(id),
    do: fields

  defp conversation_context(%{work_id: id} = fields, conn) when not is_nil(id) do
    case Query.one(conn, "SELECT conversation_id FROM works WHERE id = ?", [id]) do
      {:ok, %{conversation_id: conversation_id}} ->
        Map.put(fields, :conversation_id, conversation_id)

      _ ->
        fields
    end
  end

  defp conversation_context(%{prompt_id: id} = fields, conn) when not is_nil(id) do
    case Query.one(conn, "SELECT conversation_id FROM prompts WHERE id = ?", [id]) do
      {:ok, %{conversation_id: conversation_id}} ->
        Map.put(fields, :conversation_id, conversation_id)

      _ ->
        fields
    end
  end

  defp conversation_context(%{request_id: id} = fields, conn) when not is_nil(id) do
    case Query.one(
           conn,
           "SELECT works.conversation_id FROM requests JOIN works ON works.id = requests.work_id WHERE requests.id = ?",
           [id]
         ) do
      {:ok, %{conversation_id: conversation_id}} ->
        Map.put(fields, :conversation_id, conversation_id)

      _ ->
        fields
    end
  end

  defp conversation_context(%{inbox_id: id} = fields, conn) when not is_nil(id) do
    case Query.one(
           conn,
           "SELECT works.conversation_id FROM inbox JOIN works ON works.id = inbox.work_id WHERE inbox.id = ?",
           [id]
         ) do
      {:ok, %{conversation_id: conversation_id}} ->
        Map.put(fields, :conversation_id, conversation_id)

      _ ->
        fields
    end
  end

  defp conversation_context(fields, _conn), do: fields

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
