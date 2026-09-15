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
    id = Id.new()

    with {:ok, %{max: max}} <-
           Query.one(conn, "SELECT COALESCE(MAX(sequence), 0) AS max FROM events"),
         :ok <-
           Query.insert(conn, :events, Map.merge(fields, %{id: id, sequence: max + 1, at: now()})) do
      Query.one(conn, "SELECT * FROM events WHERE id = ?", [id])
    end
  end

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
