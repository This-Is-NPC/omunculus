defmodule Omunculus.Fixtures do
  @moduledoc """
  Inserts rows behind the store's back so tests can set up state the
  actions of the current stage cannot create yet.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Query

  @now "2026-01-01T00:00:00Z"

  @defaults %{
    prompts: %{kind: "message", body: "hi", created_at: @now},
    events: %{type: "comment", body: "{}", at: @now},
    runs: %{agent: "concierge", depth: "0", status: "open"},
    comments: %{author: "agent", kind: "note", body: "note", created_at: @now},
    works: %{title: "a work", state: "open", created_at: @now},
    requests: %{agent: "concierge", status: "waiting_human", created_at: @now},
    inbox: %{agent: "concierge", created_at: @now}
  }

  @spec insert(Exqlite.Sqlite3.db(), atom, map) :: String.t()
  def insert(conn, table, attrs \\ %{}) do
    row =
      @defaults
      |> Map.fetch!(table)
      |> Map.put(:id, Id.new())
      |> Map.merge(attrs)

    :ok = Query.insert(conn, table, row)
    row.id
  end
end
