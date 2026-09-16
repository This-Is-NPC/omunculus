defmodule Omunculus.Store.Events do
  @moduledoc """
  Appends rows to `events`, the spine of the store (spec §4): `sequence` is
  assigned as `MAX(sequence) + 1`, `id` is a fresh `Omunculus.Id`, `at` is
  the current UTC time.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Query

  @spec append(Exqlite.Sqlite3.db(), map) :: {:ok, map} | {:error, term}
  def append(conn, fields) do
    fields = run_context(conn, fields)
    id = Id.new()

    with {:ok, %{max: max}} <-
           Query.one(conn, "SELECT COALESCE(MAX(sequence), 0) AS max FROM events"),
         :ok <-
           Query.insert(conn, :events, Map.merge(fields, %{id: id, sequence: max + 1, at: now()})) do
      Query.one(conn, "SELECT * FROM events WHERE id = ?", [id])
    end
  end

  defp run_context(conn, %{run_id: run_id} = fields) when not is_nil(run_id) do
    case Query.one(
           conn,
           "SELECT r.work_id, r.request_id, e.inbox_id FROM runs r LEFT JOIN events e ON e.id = r.event_id WHERE r.id = ?",
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

  defp run_context(_conn, fields), do: fields

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
