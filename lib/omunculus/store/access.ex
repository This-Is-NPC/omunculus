defmodule Omunculus.Store.Access do
  @moduledoc """
  Authorizes human operations against project and conversation memberships.
  Roles and their capabilities are resolved from the project's TOML.
  """

  alias Omunculus.{Config, Id, Project}
  alias Omunculus.Store.{Events, Query}

  @type principal :: %{issuer: String.t(), subject: String.t()}

  @spec check(Project.t(), principal, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def check(project, principal, capability, conversation_id \\ nil) do
    with {:ok, config} <- Config.load(project.config_path) do
      check(project.conn, config.access, principal, capability, conversation_id)
    end
  end

  @spec check(Omunculus.Store.Connection.t(), map | nil, principal, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def check(_conn, nil, %{issuer: "local"}, _capability, _conversation_id), do: :ok
  def check(_conn, nil, _principal, _capability, _conversation_id), do: {:error, :forbidden}

  def check(conn, access, principal, capability, conversation_id) do
    with {:ok, project_role} <- project_role(conn, principal),
         {:ok, conversation_role} <- conversation_role(conn, conversation_id, principal) do
      roles = [project_role, conversation_role]

      if Enum.any?(roles, &grants?(access, &1, capability)) do
        :ok
      else
        {:error, :forbidden}
      end
    end
  end

  @spec conversation_for(Project.t(), :work | :run | :request | :inbox | :prompt, String.t()) ::
          {:ok, String.t()} | {:error, term}
  def conversation_for(project, type, id) do
    sql =
      case type do
        :work ->
          "SELECT conversation_id FROM works WHERE id = ?"

        :run ->
          "SELECT conversation_id FROM runs WHERE id = ?"

        :prompt ->
          "SELECT conversation_id FROM prompts WHERE id = ?"

        :request ->
          "SELECT COALESCE(opening.conversation_id, works.conversation_id, runs.conversation_id) AS conversation_id FROM requests LEFT JOIN events opening ON opening.id = requests.event_id LEFT JOIN works ON works.id = requests.work_id LEFT JOIN runs ON runs.id = requests.run_id WHERE requests.id = ?"

        :inbox ->
          "SELECT COALESCE(works.conversation_id, runs.conversation_id) AS conversation_id FROM inbox LEFT JOIN works ON works.id = inbox.work_id LEFT JOIN runs ON runs.id = inbox.run_id WHERE inbox.id = ?"
      end

    case Query.one(project.conn, sql, [id]) do
      {:ok, %{conversation_id: conversation_id}} ->
        {:ok, conversation_id}

      {:ok, _} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @spec conversation(Project.t(), principal, String.t()) :: {:ok, map} | {:error, term}
  def conversation(project, principal, id) do
    with :ok <- check(project, principal, "conversation.read", id),
         {:ok, row} <- Query.one(project.conn, "SELECT * FROM conversations WHERE id = ?", [id]),
         true <- not is_nil(row) do
      {:ok, row}
    else
      false -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      error -> error
    end
  end

  @spec conversations(Project.t(), principal) :: {:ok, [map]} | {:error, term}
  def conversations(project, principal) do
    with {:ok, config} <- Config.load(project.config_path) do
      case check(project.conn, config.access, principal, "conversation.read", nil) do
        :ok ->
          Query.all(project.conn, "SELECT * FROM conversations ORDER BY created_at, id")

        {:error, :forbidden} ->
          with {:ok, rows} <-
                 Query.all(
                   project.conn,
                   "SELECT conversations.* FROM conversations JOIN conversation_members ON conversation_members.conversation_id = conversations.id WHERE conversation_members.issuer = ? AND conversation_members.subject = ? ORDER BY conversations.created_at, conversations.id",
                   [principal.issuer, principal.subject]
                 ) do
            {:ok,
             Enum.filter(rows, fn row ->
               check(project.conn, config.access, principal, "conversation.read", row.id) == :ok
             end)}
          end

        error ->
          error
      end
    end
  end

  @spec events(Project.t(), principal, String.t(), non_neg_integer) ::
          {:ok, [map]} | {:error, term}
  def events(project, principal, id, after_cursor) do
    with {:ok, _conversation} <- conversation(project, principal, id) do
      Query.all(
        project.conn,
        "SELECT * FROM events WHERE conversation_id = ? AND sequence > ? ORDER BY sequence LIMIT 500",
        [id, after_cursor]
      )
    end
  end

  @list_sql %{
    works: "SELECT * FROM works WHERE conversation_id = ? ORDER BY created_at, id",
    runs: "SELECT * FROM runs WHERE conversation_id = ? ORDER BY started_at, id",
    prompts: "SELECT * FROM prompts WHERE conversation_id = ? ORDER BY created_at, id",
    requests:
      "SELECT requests.* FROM requests LEFT JOIN events opening ON opening.id = requests.event_id LEFT JOIN works ON works.id = requests.work_id LEFT JOIN runs ON runs.id = requests.run_id WHERE COALESCE(opening.conversation_id, works.conversation_id, runs.conversation_id) = ? ORDER BY requests.created_at, requests.id",
    inbox:
      "SELECT inbox.* FROM inbox LEFT JOIN works ON works.id = inbox.work_id LEFT JOIN runs ON runs.id = inbox.run_id WHERE COALESCE(works.conversation_id, runs.conversation_id) = ? ORDER BY inbox.created_at, inbox.id"
  }

  @spec list(Project.t(), principal, String.t(), atom) :: {:ok, [map]} | {:error, term}
  def list(project, principal, conversation_id, kind) when is_map_key(@list_sql, kind) do
    with {:ok, _conversation} <- conversation(project, principal, conversation_id) do
      read_items(project.conn, kind, Map.fetch!(@list_sql, kind), conversation_id)
    end
  end

  @spec snapshot(Project.t(), principal, String.t()) :: {:ok, map} | {:error, term}
  def snapshot(project, principal, conversation_id) do
    Query.transaction(project.conn, fn ->
      with {:ok, conversation} <- conversation(project, principal, conversation_id),
           {:ok, items} <- snapshot_items(project, conversation_id),
           {:ok, %{cursor: cursor}} <-
             Query.one(
               project.conn,
               "SELECT COALESCE(MAX(sequence), 0) AS cursor FROM events WHERE conversation_id = ?",
               [conversation_id]
             ) do
        {:ok, %{conversation: conversation, items: items, cursor: cursor}}
      end
    end)
  end

  defp snapshot_items(project, conversation_id) do
    Enum.reduce_while(@list_sql, {:ok, %{}}, fn {kind, sql}, {:ok, acc} ->
      case read_items(project.conn, kind, sql, conversation_id) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, kind, rows)}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_items(conn, kind, sql, conversation_id) do
    with {:ok, rows} <- Query.all(conn, sql, [conversation_id]) do
      if kind == :requests do
        Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, requests} ->
          case Omunculus.Store.View.view(conn, "request", row.id) do
            {:ok, request} -> {:cont, {:ok, requests ++ [request]}}
            error -> {:halt, error}
          end
        end)
      else
        {:ok, rows}
      end
    end
  end

  @spec receipt(Project.t(), principal, String.t()) :: {:ok, map | nil} | {:error, term}
  def receipt(project, principal, command_id) do
    Query.one(
      project.conn,
      "SELECT operation, result FROM command_receipts WHERE issuer = ? AND subject = ? AND command_id = ?",
      [principal.issuer, principal.subject, command_id]
    )
  end

  @spec reply_needs_project_config?(Project.t(), String.t(), map) ::
          {:ok, boolean} | {:error, term}
  def reply_needs_project_config?(project, request_id, answer) do
    with {:ok, request} <- Omunculus.Store.View.view(project.conn, "request", request_id) do
      {:ok, request && needs_config?(request, answer)}
    end
  end

  defp needs_config?(request, answer) do
    parts = if is_map(answer["parts"]), do: answer["parts"], else: %{}
    calls = Jason.decode!(request.options)[answer["option"]] || []

    Enum.any?(calls, fn call ->
      call["name"] == "grant" and not is_nil(get_in(call, ["args", "scope"]))
    end) or
      Enum.any?(parts, fn {part, value} ->
        is_map(value) and Map.has_key?(request.origins, part) and
          needs_config?(request.origins[part], value)
      end)
  end

  @spec create_conversation(Project.t(), principal, String.t() | nil) ::
          {:ok, map} | {:error, term}
  def create_conversation(project, principal, command_id \\ nil) do
    with {:ok, config} <- Config.load(project.config_path),
         access when is_map(access) <- config.access do
      Query.transaction(project.conn, fn ->
        with :ok <- check(project.conn, access, principal, "conversation.create", nil),
             {:ok, prior} <- create_receipt(project, principal, command_id) do
          case prior do
            nil ->
              insert_conversation(project, access, principal, command_id)

            %{operation: "conversation.create", result: result} ->
              data = Jason.decode!(result)
              {:ok, %{id: data["id"], cursor: data["cursor"]}}

            _ ->
              {:error, :command_id_conflict}
          end
        end
      end)
    else
      _ -> {:error, :access_disabled}
    end
  end

  defp create_receipt(_project, _principal, nil), do: {:ok, nil}
  defp create_receipt(project, principal, id), do: receipt(project, principal, id)

  defp insert_conversation(project, access, principal, command_id) do
    id = Id.new()
    at = Events.now()

    with :ok <-
           Query.insert(project.conn, :conversations, %{
             id: id,
             created_issuer: principal.issuer,
             created_subject: principal.subject,
             created_at: at
           }),
         :ok <-
           insert_member(project.conn, :conversation_members, principal,
             conversation_id: id,
             role: access.creator_role,
             at: at
           ),
         {:ok, event} <-
           Events.append(project.conn, %{
             type: "conversation",
             actor_kind: "human",
             conversation_id: id,
             actor_issuer: principal.issuer,
             actor_subject: principal.subject,
             body: "{}"
           }),
         result = %{id: id, cursor: event.sequence},
         :ok <- record_create_receipt(project, principal, command_id, result) do
      {:ok, result}
    end
  end

  defp record_create_receipt(_project, _principal, nil, _result), do: :ok

  defp record_create_receipt(project, principal, id, result) do
    Query.insert(project.conn, :command_receipts, %{
      issuer: principal.issuer,
      subject: principal.subject,
      command_id: id,
      operation: "conversation.create",
      result: Jason.encode!(result),
      created_at: Events.now()
    })
  end

  @spec bootstrap(Project.t(), principal) :: :ok | {:error, term}
  def bootstrap(project, principal) do
    with {:ok, config} <- Config.load(project.config_path),
         access when is_map(access) <- config.access do
      Query.transaction(project.conn, fn ->
        with {:ok, %{n: 0}} <-
               Query.one(project.conn, "SELECT COUNT(*) AS n FROM project_members"),
             :ok <-
               insert_member(project.conn, :project_members, principal,
                 role: access.bootstrap_role,
                 at: Events.now()
               ),
             {:ok, _event} <-
               Events.append(project.conn, %{
                 type: "access.bootstrap",
                 actor_kind: "human",
                 actor_issuer: principal.issuer,
                 actor_subject: principal.subject,
                 body: Jason.encode!(%{role: access.bootstrap_role})
               }) do
          {:ok, :bootstrapped}
        else
          {:ok, _present} -> {:error, :already_bootstrapped}
          error -> error
        end
      end)
      |> case do
        {:ok, :bootstrapped} -> :ok
        error -> error
      end
    else
      _ -> {:error, :access_disabled}
    end
  end

  @spec put_member(Project.t(), principal, principal, String.t(), String.t() | nil) ::
          :ok | {:error, term}
  def put_member(project, actor, target, role, conversation_id \\ nil) do
    with {:ok, config} <- Config.load(project.config_path),
         access when is_map(access) <- config.access,
         {:ok, role_spec} <- fetch_role(access, role, conversation_id),
         :ok <- conversation_exists(project.conn, conversation_id) do
      Query.transaction(project.conn, fn ->
        with :ok <- manage(project, access, actor, conversation_id),
             :ok <- can_assign(project, access, actor, role_spec.capabilities, conversation_id),
             :ok <- upsert_member(project.conn, target, role, conversation_id),
             {:ok, _event} <-
               access_event(project.conn, "access.member", actor, target, role, conversation_id) do
          {:ok, :updated}
        end
      end)
      |> ok_atom()
    else
      nil -> {:error, :access_disabled}
      error -> error
    end
  end

  @spec remove_member(Project.t(), principal, principal, String.t() | nil) ::
          :ok | {:error, term}
  def remove_member(project, actor, target, conversation_id \\ nil) do
    with {:ok, config} <- Config.load(project.config_path),
         access when is_map(access) <- config.access,
         :ok <- conversation_exists(project.conn, conversation_id) do
      Query.transaction(project.conn, fn ->
        with :ok <- manage(project, access, actor, conversation_id),
             {:ok, current_role} <- member_role(project.conn, target, conversation_id),
             :ok <- can_remove(project, access, actor, current_role, conversation_id),
             :ok <- delete_member(project.conn, target, conversation_id),
             {:ok, _event} <-
               access_event(project.conn, "access.revoke", actor, target, nil, conversation_id) do
          {:ok, :removed}
        end
      end)
      |> ok_atom()
    else
      nil -> {:error, :access_disabled}
      error -> error
    end
  end

  defp conversation_exists(_conn, nil), do: :ok

  defp conversation_exists(conn, id) do
    case Query.one(conn, "SELECT id FROM conversations WHERE id = ?", [id]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, _row} -> :ok
      error -> error
    end
  end

  defp ok_atom({:ok, _}), do: :ok
  defp ok_atom(error), do: error

  defp fetch_role(access, role, conversation_id) do
    scope = if is_nil(conversation_id), do: "project", else: "conversation"

    case Map.get(access.roles, role) do
      %{scope: ^scope} = spec -> {:ok, spec}
      _ -> {:error, :invalid_role}
    end
  end

  defp manage(project, access, actor, nil),
    do: check(project.conn, access, actor, "project.manage_access", nil)

  defp manage(project, access, actor, conversation_id),
    do: check(project.conn, access, actor, "conversation.manage_access", conversation_id)

  defp can_assign(project, access, actor, caps, conversation_id) do
    if Enum.all?(caps, fn cap ->
         check(project.conn, access, actor, cap, conversation_id) == :ok
       end) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp can_remove(_project, _access, _actor, nil, _conversation_id), do: {:error, :not_found}

  defp can_remove(project, access, actor, role, conversation_id) do
    with %{capabilities: caps} <- Map.get(access.roles, role),
         :ok <- can_assign(project, access, actor, caps, conversation_id) do
      if is_nil(conversation_id) and role == access.bootstrap_role do
        with {:ok, %{n: n}} <-
               Query.one(
                 project.conn,
                 "SELECT COUNT(*) AS n FROM project_members WHERE role = ?",
                 [
                   role
                 ]
               ) do
          if n > 1, do: :ok, else: {:error, :last_administrator}
        end
      else
        :ok
      end
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp member_role(conn, principal, nil), do: project_role(conn, principal)

  defp member_role(conn, principal, conversation_id),
    do: conversation_role(conn, conversation_id, principal)

  defp upsert_member(conn, principal, role, nil) do
    Query.exec(
      conn,
      "INSERT INTO project_members (issuer, subject, role, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT (issuer, subject) DO UPDATE SET role = excluded.role, updated_at = excluded.updated_at",
      [principal.issuer, principal.subject, role, Events.now()]
    )
  end

  defp upsert_member(conn, principal, role, conversation_id) do
    Query.exec(
      conn,
      "INSERT INTO conversation_members (conversation_id, issuer, subject, role, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (conversation_id, issuer, subject) DO UPDATE SET role = excluded.role, updated_at = excluded.updated_at",
      [conversation_id, principal.issuer, principal.subject, role, Events.now()]
    )
  end

  defp delete_member(conn, principal, nil) do
    Query.exec(conn, "DELETE FROM project_members WHERE issuer = ? AND subject = ?", [
      principal.issuer,
      principal.subject
    ])
  end

  defp delete_member(conn, principal, conversation_id) do
    Query.exec(
      conn,
      "DELETE FROM conversation_members WHERE conversation_id = ? AND issuer = ? AND subject = ?",
      [conversation_id, principal.issuer, principal.subject]
    )
  end

  defp access_event(conn, type, actor, target, role, conversation_id) do
    Events.append(conn, %{
      type: type,
      actor_kind: "human",
      conversation_id: conversation_id,
      actor_issuer: actor.issuer,
      actor_subject: actor.subject,
      body: Jason.encode!(%{issuer: target.issuer, subject: target.subject, role: role})
    })
  end

  defp project_role(conn, principal) do
    with {:ok, row} <-
           Query.one(conn, "SELECT role FROM project_members WHERE issuer = ? AND subject = ?", [
             principal.issuer,
             principal.subject
           ]) do
      {:ok, row && row.role}
    end
  end

  defp conversation_role(_conn, nil, _principal), do: {:ok, nil}

  defp conversation_role(conn, id, principal) do
    with {:ok, row} <-
           Query.one(
             conn,
             "SELECT role FROM conversation_members WHERE conversation_id = ? AND issuer = ? AND subject = ?",
             [id, principal.issuer, principal.subject]
           ) do
      {:ok, row && row.role}
    end
  end

  defp grants?(_access, nil, _capability), do: false

  defp grants?(access, role, capability) do
    case Map.get(access.roles, role) do
      %{capabilities: caps} -> capability in caps
      _ -> false
    end
  end

  defp insert_member(conn, table, principal, opts) do
    Query.insert(
      conn,
      table,
      Map.merge(
        %{issuer: principal.issuer, subject: principal.subject},
        %{role: opts[:role], updated_at: opts[:at]}
      )
      |> maybe_conversation(opts)
    )
  end

  defp maybe_conversation(row, opts) do
    case opts[:conversation_id] do
      nil -> row
      id -> Map.put(row, :conversation_id, id)
    end
  end
end
