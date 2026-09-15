defmodule Omunculus.Store.Actions.Helpers do
  @moduledoc """
  Shared machinery between `Actions` and `Actions.Sequence`: existence
  checks and error tagging (spec §8.3), the `COMMENTS` insert every
  action that writes one reuses, reopening a waiting work, a new work's
  depth and its stage/assignee from the workflow, inserting the `WORKS`
  row itself, and the ancestor grants walk of spec §5.
  """

  alias Omunculus.Config
  alias Omunculus.Store.{Events, Query, View}

  @forbidden ~w(stage agent model)

  @spec ensure_exist(Exqlite.Sqlite3.db(), [{atom, String.t() | nil}]) :: :ok | {:error, term}
  def ensure_exist(conn, targets) do
    targets
    |> Enum.reject(fn {_table, id} -> is_nil(id) end)
    |> Enum.reduce_while(:ok, fn {table, id}, :ok ->
      case Query.one(conn, "SELECT id FROM #{table} WHERE id = ?", [id]) do
        {:ok, nil} -> {:halt, {:error, {:missing, table, id}}}
        {:ok, _row} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec tag_error(atom, :ok | {:ok, term} | {:error, term}) ::
          :ok | {:ok, term} | {:error, {atom, term}}
  def tag_error(_tag, :ok), do: :ok
  def tag_error(_tag, {:ok, _value} = ok), do: ok
  def tag_error(tag, {:error, reason}), do: {:error, {tag, reason}}

  @spec ensure_no_forbidden(atom, map) :: :ok | {:error, {atom, {:forbidden, String.t()}}}
  def ensure_no_forbidden(tag, body) do
    case Enum.find(@forbidden, &Map.has_key?(body, &1)) do
      nil -> :ok
      key -> {:error, {tag, {:forbidden, key}}}
    end
  end

  @spec insert_comment(Exqlite.Sqlite3.db(), String.t(), map, String.t(), map, map) ::
          :ok | {:error, term}
  def insert_comment(conn, id, targets, text, event, ctx) do
    Query.insert(conn, :comments, %{
      id: id,
      work_id: targets[:works],
      request_id: targets[:requests],
      inbox_id: targets[:inbox],
      run_id: ctx.run_id,
      event_id: event.id,
      author: ctx.author,
      kind: "note",
      body: text,
      created_at: event.at
    })
  end

  @spec reopen_work(Exqlite.Sqlite3.db(), String.t() | nil) :: :ok | {:error, term}
  def reopen_work(_conn, nil), do: :ok

  def reopen_work(conn, work_id) do
    Query.exec(
      conn,
      "UPDATE works SET state = 'open', waiting = NULL, waiting_for = NULL, waiting_from = NULL, updated_at = ? WHERE id = ?",
      [Events.now(), work_id]
    )
  end

  @spec depth_at(Exqlite.Sqlite3.db(), String.t() | nil) ::
          {:ok, non_neg_integer} | {:error, term}
  def depth_at(_conn, nil), do: {:ok, 0}

  def depth_at(conn, parent_id) do
    case Query.one(conn, "SELECT * FROM works WHERE id = ?", [parent_id]) do
      {:ok, nil} -> {:error, {:missing, :works, parent_id}}
      {:ok, parent} -> {:ok, View.work_depth(conn, parent) + 1}
      {:error, _reason} = error -> error
    end
  end

  @spec stage_and_assignee(Config.t(), non_neg_integer, (-> {:ok, String.t()} | {:error, term})) ::
          {:ok, {String.t() | nil, String.t()}} | {:error, term}
  def stage_and_assignee(config, depth, fallback_agent) do
    case Config.workflow_for(config, depth) do
      {:ok, [step | _rest]} -> {:ok, {step.name, step.agent}}
      :off -> with {:ok, agent} <- fallback_agent.(), do: {:ok, {nil, agent}}
    end
  end

  @spec insert_work(Exqlite.Sqlite3.db(), map) :: :ok | {:error, term}
  def insert_work(conn, work) do
    Query.insert(conn, :works, %{
      id: work.id,
      parent_id: work.parent_id,
      event_id: work.event_id,
      assignee: work.assignee,
      title: work.title,
      stage: work.stage,
      state: "open",
      created_at: work.at,
      updated_at: work.at
    })
  end

  @spec fetch_work(Exqlite.Sqlite3.db(), String.t() | nil) :: {:ok, map | nil} | {:error, term}
  def fetch_work(_conn, nil), do: {:ok, nil}

  def fetch_work(conn, work_id),
    do: Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])

  @spec grants(Exqlite.Sqlite3.db(), map | nil) :: {:ok, [String.t()]}
  def grants(_conn, nil), do: {:ok, []}

  def grants(conn, work) do
    with {:ok, parent} <- fetch_work(conn, work.parent_id),
         {:ok, above} <- grants(conn, parent) do
      {:ok, Enum.uniq(work_grants(work) ++ above)}
    end
  end

  defp work_grants(%{grants: nil}), do: []
  defp work_grants(%{grants: json}), do: Jason.decode!(json)
end
