defmodule Omunculus.Store.Actions.Helpers do
  @moduledoc """
  Shared machinery between the `Actions` modules: existence
  checks and error tagging (spec §8.3), the `COMMENTS` insert every
  action that writes one reuses, reopening a waiting work, a new work's
  stage and assignee from the workflow, the named agent or the depth's
  first agent, resolving its `workspace` from a given name, its parent,
  or the project's default (spec §9.1), inserting the `WORKS` row itself,
  fetching a request by id, and the ancestor grants walk of spec §5.
  """

  alias Omunculus.Config
  alias Omunculus.Store.{Events, Query}

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
    case Enum.find(forbidden(tag), &Map.has_key?(body, &1)) do
      nil -> :ok
      key -> {:error, {tag, {:forbidden, key}}}
    end
  end

  # `work` and `delegate` may name the new work's agent; `stage_and_assignee`
  # checks it against the TOML.
  defp forbidden(tag) when tag in [:work, :delegate], do: @forbidden -- ["agent"]
  defp forbidden(_tag), do: @forbidden

  @spec ensure_title(atom, map) :: :ok | {:error, {atom, :no_title}}
  def ensure_title(_tag, %{"title" => title}) when is_binary(title) and title != "", do: :ok
  def ensure_title(tag, _body), do: {:error, {tag, :no_title}}

  @spec ensure_goal(atom, map) :: :ok | {:error, {atom, :no_goal}}
  def ensure_goal(_tag, %{"goal" => goal}) when is_binary(goal) and goal != "", do: :ok
  def ensure_goal(tag, _body), do: {:error, {tag, :no_goal}}

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

  @spec stage_and_assignee(Config.t(), non_neg_integer, String.t() | nil) ::
          {:ok, {String.t() | nil, String.t()}} | {:error, term}
  def stage_and_assignee(config, depth, agent) do
    case {Config.workflow_for(config, depth), agent} do
      {{:ok, [step | _rest]}, nil} ->
        {:ok, {step.name, step.agent}}

      {{:ok, _steps}, _agent} ->
        {:error, :agent_with_workflow}

      {:off, nil} ->
        with {:ok, {name, _agent}} <- Config.agent_at_depth(config, depth), do: {:ok, {nil, name}}

      {:off, agent} ->
        if List.keymember?(Config.agents_at_depth(config, depth), agent, 0),
          do: {:ok, {nil, agent}},
          else: {:error, {:agent_not_allowed, agent}}
    end
  end

  @spec insert_work(Exqlite.Sqlite3.db(), map) :: :ok | {:error, term}
  def insert_work(conn, work) do
    Query.insert(conn, :works, %{
      id: work.id,
      parent_id: work.parent_id,
      event_id: work.event_id,
      workspace: work.workspace,
      assignee: work.assignee,
      title: work.title,
      goal: work.goal,
      stage: work.stage,
      state: "open",
      created_at: work.at,
      updated_at: work.at
    })
  end

  @spec resolve_workspace(Config.t(), String.t() | nil, map | nil) ::
          {:ok, String.t() | nil} | {:error, {:unknown_workspace, String.t()}}
  def resolve_workspace(config, nil, nil), do: {:ok, config.policy_workspace}
  def resolve_workspace(_config, nil, parent), do: {:ok, parent.workspace}

  def resolve_workspace(config, name, _parent) do
    if Map.has_key?(config.workspaces, name) do
      {:ok, name}
    else
      {:error, {:unknown_workspace, name}}
    end
  end

  @spec fetch_work(Exqlite.Sqlite3.db(), String.t() | nil) :: {:ok, map | nil} | {:error, term}
  def fetch_work(_conn, nil), do: {:ok, nil}

  def fetch_work(conn, work_id),
    do: Query.one(conn, "SELECT * FROM works WHERE id = ?", [work_id])

  @spec fetch_request(atom, Exqlite.Sqlite3.db(), String.t() | nil) ::
          {:ok, map} | {:error, term}
  def fetch_request(tag, _conn, nil), do: {:error, {tag, :no_request}}

  def fetch_request(tag, conn, request_id) do
    with :ok <- tag_error(tag, ensure_exist(conn, [{:requests, request_id}])) do
      Query.one(conn, "SELECT * FROM requests WHERE id = ?", [request_id])
    end
  end

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
