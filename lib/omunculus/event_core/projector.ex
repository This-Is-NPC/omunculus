defmodule Omunculus.EventCore.Projector do
  @moduledoc """
  Consumer that reduces `EVENTS` into the six domain/archive projections.

  It keeps a cursor (`PROJECTION_CURSORS`) and applies every event after that
  cursor in a transaction that also advances the cursor, so redelivery, restart
  and replay never apply the same event twice. Each reducer additionally checks
  the row's `last_sequence` and its status precondition: a stale delivery is a
  no-op. `rebuild/1` drops the projections and replays the whole log.
  """

  use GenServer

  alias Omunculus.EventCore
  alias Omunculus.EventCore.Store

  @projection "domain"
  @batch 500

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Block until every committed event has been applied."
  def sync(projector), do: GenServer.call(projector, :sync, :infinity)

  @doc "Drop projections and replay the log from sequence 0."
  def rebuild(projector), do: GenServer.call(projector, :rebuild, :infinity)

  def sync_core(core), do: catch_up(core)

  def cursor(projector), do: GenServer.call(projector, :cursor, :infinity)

  @doc "Deterministic snapshot of all projection tables, for replay equality checks."
  def snapshot(core) do
    Map.new(Store.projection_tables(), fn table ->
      {table, EventCore.query(core, "SELECT * FROM #{table} ORDER BY 1")}
    end)
  end

  @impl true
  def init(opts) do
    core = Keyword.fetch!(opts, :core)
    :ok = EventCore.subscribe(core)
    {:ok, %{core: core}, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    catch_up(state.core)
    {:noreply, state}
  end

  @impl true
  def handle_info({:event_core, _env}, state) do
    catch_up(state.core)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    catch_up(state.core)
    {:reply, :ok, state}
  end

  def handle_call(:rebuild, _from, state) do
    {:ok, _} =
      EventCore.transaction(state.core, fn conn ->
        Enum.each(Store.projection_tables(), &Store.exec!(conn, "DELETE FROM #{&1}"))
        Store.query(conn, "DELETE FROM PROJECTION_CURSORS WHERE projection = ?", [@projection])
      end)

    catch_up(state.core)
    {:reply, :ok, state}
  end

  def handle_call(:cursor, _from, state) do
    {:reply, read_cursor(state.core), state}
  end

  # --- catch up ----------------------------------------------------------------

  defp catch_up(core) do
    cursor = read_cursor(core)
    events = EventCore.stream(core, cursor, limit: @batch)

    Enum.each(events, fn env ->
      {:ok, _} =
        EventCore.transaction(core, fn conn ->
          if env.sequence > cursor_in(conn) do
            rejected? =
              Store.query(
                conn,
                "SELECT 1 FROM EVENTS WHERE type = 'delivery.rejected' AND json_extract(payload, '$.rejected_event_id') = ? LIMIT 1",
                [env.event_id]
              ) != []

            unless rejected? do
              if env.type == "delivery.rejected" do
                # Another process may have projected the original before the
                # resident owner rejected delivery. Reconcile atomically.
                Enum.each(Store.projection_tables(), &Store.exec!(conn, "DELETE FROM #{&1}"))
                cols = Enum.join(Omunculus.Event.Envelope.columns(), ", ")

                Store.query(
                  conn,
                  "SELECT #{cols} FROM EVENTS e WHERE sequence <= ? AND NOT EXISTS (SELECT 1 FROM EVENTS r WHERE r.type = 'delivery.rejected' AND json_extract(r.payload, '$.rejected_event_id') = e.event_id) ORDER BY sequence",
                  [env.sequence]
                )
                |> Enum.each(fn row ->
                  apply_event(conn, Omunculus.Event.Envelope.from_row(row))
                end)
              else
                apply_event(conn, env)
              end
            end

            set_cursor(conn, env.sequence)
          end
        end)
    end)

    if length(events) == @batch, do: catch_up(core), else: :ok
  end

  defp read_cursor(core) do
    case EventCore.query(
           core,
           "SELECT last_sequence FROM PROJECTION_CURSORS WHERE projection = ?",
           [
             @projection
           ]
         ) do
      [[n]] -> n
      [] -> 0
    end
  end

  defp cursor_in(conn) do
    case Store.one(conn, "SELECT last_sequence FROM PROJECTION_CURSORS WHERE projection = ?", [
           @projection
         ]) do
      [n] -> n
      nil -> 0
    end
  end

  defp set_cursor(conn, seq) do
    Store.query(
      conn,
      "INSERT INTO PROJECTION_CURSORS (projection, last_sequence) VALUES (?, ?) ON CONFLICT(projection) DO UPDATE SET last_sequence = excluded.last_sequence",
      [@projection, seq]
    )
  end

  # --- reducers ----------------------------------------------------------------
  # Every reducer is a pure function of (projection row, envelope). Stale or
  # out-of-order deliveries become no-ops via `last_sequence` / status checks.

  defp apply_event(_conn, %{type: "task.requested", payload: %{"requested_by" => _}}), do: :ok

  defp apply_event(conn, %{type: "task.requested"} = env) do
    p = env.payload
    workspace_id = p["workspace"]

    Store.query(
      conn,
      "INSERT OR IGNORE INTO WORK_ITEMS (work_item_id, project_id, workspace_id, parent_work_item_id, instruction, status, version, created_at, updated_at, last_sequence) VALUES (?, ?, ?, NULL, ?, 'to_do', 0, ?, ?, ?)",
      [
        env.work_item_id,
        env.project_id,
        workspace_id,
        p["instruction"],
        env.occurred_at,
        env.occurred_at,
        env.sequence
      ]
    )

    if workspace_id do
      Store.query(
        conn,
        "UPDATE WORK_ITEMS SET workspace_id = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
        [workspace_id, env.sequence, env.work_item_id, env.sequence]
      )
    end
  end

  defp apply_event(conn, %{type: "task.delegated"} = env) do
    p = env.payload
    child = p["child_work_item_id"]

    Store.query(
      conn,
      "INSERT OR IGNORE INTO WORK_ITEMS (work_item_id, project_id, parent_work_item_id, instruction, status, version, created_at, updated_at, last_sequence) VALUES (?, ?, ?, ?, 'to_do', 0, ?, ?, ?)",
      [
        child,
        env.project_id,
        env.work_item_id,
        p["instruction"],
        env.occurred_at,
        env.occurred_at,
        env.sequence
      ]
    )

    Store.query(
      conn,
      "INSERT OR IGNORE INTO WORK_ITEM_DEPENDENCIES (project_id, work_item_id, depends_on_work_item_id, last_sequence) VALUES (?, ?, ?, ?)",
      [env.project_id, env.work_item_id, child, env.sequence]
    )

    if p["requested_by"] do
      Store.query(conn, "UPDATE WORK_ITEMS SET requested_by = ? WHERE work_item_id = ?", [
        p["requested_by"],
        child
      ])
    end

    if requester = p["requester_work_item_id"] do
      Store.query(
        conn,
        "INSERT OR IGNORE INTO WORK_ITEM_DEPENDENCIES (project_id, work_item_id, depends_on_work_item_id, last_sequence) VALUES (?, ?, ?, ?)",
        [env.project_id, requester, child, env.sequence]
      )
    end

    child_workspace = p["workspace"] || env.workspace_id

    if child_workspace do
      Store.query(
        conn,
        "UPDATE WORK_ITEMS SET workspace_id = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence <= ?",
        [child_workspace, env.sequence, child, env.sequence]
      )
    end

    transition_work_item(conn, env.work_item_id, ["running", "active"], "waiting", env)
  end

  defp apply_event(conn, %{type: "run.started"} = env) do
    p = env.payload

    Store.query(
      conn,
      "INSERT OR IGNORE INTO ARCHIVE_RUNS (run_id, project_id, work_item_id, attempt, depth, parent_run_id, originating_run_id, agent_id, agent_kind, trace_id, status, reason, started_at, last_sequence) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)",
      [
        env.run_id,
        env.project_id,
        env.work_item_id,
        p["attempt"],
        p["depth"],
        p["parent_run_id"],
        p["originating_run_id"],
        p["agent_id"],
        p["agent_kind"],
        env.correlation_id,
        to_string(p["reason"]),
        env.occurred_at,
        env.sequence
      ]
    )

    if p["attempt"] == 1 and get_in(p, ["flow", "steps"]) not in [nil, []] do
      Store.query(
        conn,
        "UPDATE WORK_ITEMS SET status = ? WHERE work_item_id = ? AND status = 'to_do'",
        [hd(p["flow"]["steps"])["name"], env.work_item_id]
      )
    end

    transition_work_item(
      conn,
      env.work_item_id,
      ["active", "failed", "waiting", "idle"],
      "running",
      env
    )
  end

  defp apply_event(conn, %{type: "tool.call.completed"} = env) do
    case env.payload["checkpoint"] do
      nil ->
        :ok

      checkpoint ->
        Store.query(
          conn,
          "UPDATE WORK_ITEMS SET checkpoint = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
          [
            Jason.encode!(checkpoint),
            env.occurred_at,
            env.sequence,
            env.work_item_id,
            env.sequence
          ]
        )
    end
  end

  defp apply_event(conn, %{type: type} = env)
       when type in ["model.call.completed", "model.call.failed"] do
    p = env.payload

    Store.query(
      conn,
      "INSERT OR IGNORE INTO ARCHIVE_MODEL_CALLS (call_id, run_id, trace_id, round, model, usage, outcome, duration_ms, occurred_at, last_sequence) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        env.event_id,
        env.run_id,
        env.correlation_id,
        p["round"],
        p["model"],
        Jason.encode!(p["usage"] || %{}),
        if(type == "model.call.failed", do: "failed", else: p["outcome"]),
        p["duration_ms"],
        env.occurred_at,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "task.completed"} = env) do
    p = env.payload

    changed =
      Store.query(
        conn,
        "UPDATE WORK_ITEMS SET status = 'completed', state = 'idle', awaiting = NULL, result = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND status != 'completed' AND last_sequence < ?",
        [to_string(p["result"]), env.occurred_at, env.sequence, env.work_item_id, env.sequence]
      )

    _ = changed

    Store.query(
      conn,
      "INSERT OR IGNORE INTO COMMENTS (comment_id, session_id, work_item_id, kind, body, created_at, event_id, last_sequence) VALUES (?, ?, ?, 'result', ?, ?, ?, ?)",
      [
        env.event_id,
        env.session_id,
        env.work_item_id,
        to_string(p["result"]),
        env.occurred_at,
        env.event_id,
        env.sequence
      ]
    )

    :ok
  end

  defp apply_event(conn, %{type: "run.completed"} = env) do
    p = env.payload
    outcome = p["outcome"]

    Store.query(
      conn,
      "UPDATE ARCHIVE_RUNS SET status = ?, outcome = ?, finished_at = ?, last_sequence = ? WHERE run_id = ? AND status = 'running' AND last_sequence < ?",
      [outcome, outcome, env.occurred_at, env.sequence, env.run_id, env.sequence]
    )

    if is_binary(p["comment"]) and p["comment"] != "" do
      apply_event(conn, %{
        env
        | type: "task.commented",
          payload: %{"kind" => "run", "body" => p["comment"]}
      })
    end

    p =
      if outcome == "reported" and is_map(p["assessment"]),
        do: Map.put(p, "checkpoint", p["assessment"]["restore"] || %{}),
        else: p

    p =
      if outcome == "reported",
        do: Map.put(p, "awaiting", p["checkpoint"]["awaiting"] || []),
        else: p

    case outcome do
      status when status in ["waiting", "reported"] ->
        Store.query(
          conn,
          "UPDATE WORK_ITEMS SET state = 'waiting', awaiting = ?, checkpoint = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
          [
            Jason.encode!(p["awaiting"] || []),
            Jason.encode!(p["checkpoint"] || %{}),
            env.occurred_at,
            env.sequence,
            env.work_item_id,
            env.sequence
          ]
        )

      _ ->
        :ok
    end
  end

  defp apply_event(conn, %{type: type} = env)
       when type in ["task.break", "task.assessment_requested"] do
    transition_work_item(conn, env.work_item_id, ["active", "running", "waiting"], "waiting", env)
  end

  defp apply_event(conn, %{type: "task.advanced"} = env) do
    p = env.payload

    Store.query(
      conn,
      "UPDATE WORK_ITEMS SET status = ?, state = 'active', checkpoint = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND status = ? AND last_sequence < ?",
      [
        p["to"],
        Jason.encode!(p["checkpoint"]),
        env.occurred_at,
        env.sequence,
        env.work_item_id,
        p["from"],
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "task.run_requested"} = env) do
    Store.query(
      conn,
      "UPDATE WORK_ITEMS SET state = 'active', status = ?, checkpoint = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND status != 'completed' AND last_sequence < ?",
      [
        env.payload["stage"],
        Jason.encode!(env.payload["checkpoint"]),
        env.occurred_at,
        env.sequence,
        env.work_item_id,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "run.failed"} = env) do
    Store.query(
      conn,
      "UPDATE ARCHIVE_RUNS SET status = 'failed', finished_at = ?, last_sequence = ? WHERE run_id = ? AND status = 'running' AND last_sequence < ?",
      [env.occurred_at, env.sequence, env.run_id, env.sequence]
    )

    transition_work_item(conn, env.work_item_id, ["running", "waiting"], "failed", env)
  end

  defp apply_event(_conn, %{type: "session.created"}), do: :ok

  defp apply_event(conn, %{type: "workspace.attached"} = env) do
    p = env.payload
    workspace_id = p["workspace_id"]

    Store.query(
      conn,
      """
      INSERT INTO SESSION_WORKSPACES (workspace_id, roots, teams, attached, attached_at, last_sequence)
      VALUES (?, ?, ?, 1, ?, ?)
      ON CONFLICT(workspace_id) DO UPDATE SET
        roots = excluded.roots,
        teams = excluded.teams,
        attached = 1,
        attached_at = excluded.attached_at,
        last_sequence = excluded.last_sequence
      WHERE last_sequence < excluded.last_sequence
      """,
      [
        workspace_id,
        Jason.encode!(p["roots"] || []),
        Jason.encode!(p["teams"] || []),
        env.occurred_at,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "workspace.detached"} = env) do
    workspace_id = env.payload["workspace_id"]

    Store.query(
      conn,
      "UPDATE SESSION_WORKSPACES SET attached = 0, last_sequence = ? WHERE workspace_id = ? AND last_sequence < ?",
      [env.sequence, workspace_id, env.sequence]
    )
  end

  defp apply_event(conn, %{type: "task.commented"} = env) do
    p = env.payload
    kind = p["kind"] || "comment"

    Store.query(
      conn,
      "INSERT OR IGNORE INTO COMMENTS (comment_id, session_id, work_item_id, kind, body, created_at, event_id, last_sequence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        env.event_id,
        env.session_id,
        env.work_item_id,
        kind,
        p["body"],
        env.occurred_at,
        env.event_id,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "permission.requested"} = env) do
    p = env.payload

    Store.query(
      conn,
      "INSERT OR IGNORE INTO COMMENTS (comment_id, session_id, work_item_id, kind, body, created_at, event_id, last_sequence) VALUES (?, ?, ?, 'request', ?, ?, ?, ?)",
      [
        env.event_id,
        env.session_id,
        env.work_item_id,
        permission_request_body(p),
        env.occurred_at,
        env.event_id,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "permission.granted"} = env) do
    p = env.payload

    Store.query(
      conn,
      "INSERT OR IGNORE INTO COMMENTS (comment_id, session_id, work_item_id, kind, body, created_at, event_id, last_sequence) VALUES (?, ?, ?, 'response', ?, ?, ?, ?)",
      [
        env.event_id,
        env.session_id,
        env.work_item_id,
        "#{p["kind"]} by #{p["granter"]}",
        env.occurred_at,
        env.event_id,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "permission.denied"} = env) do
    p = env.payload

    Store.query(
      conn,
      "INSERT OR IGNORE INTO COMMENTS (comment_id, session_id, work_item_id, kind, body, created_at, event_id, last_sequence) VALUES (?, ?, ?, 'response', ?, ?, ?, ?)",
      [
        env.event_id,
        env.session_id,
        env.work_item_id,
        p["reason"],
        env.occurred_at,
        env.event_id,
        env.sequence
      ]
    )
  end

  defp apply_event(conn, %{type: "inbox.read"} = env) do
    id = env.payload["id"]

    Store.query(
      conn,
      "UPDATE COMMENTS SET read_at = ?, last_sequence = ? WHERE (comment_id = ? OR event_id = ?) AND last_sequence < ?",
      [env.occurred_at, env.sequence, id, id, env.sequence]
    )
  end

  # Commands and events without a projection effect (tool.call.requested,
  # task.resumed, ...) are still consumed: the cursor advances past them.
  defp apply_event(_conn, _env), do: :ok

  defp permission_request_body(payload) do
    case payload do
      %{"reason" => reason} when is_binary(reason) and reason != "" -> reason
      %{"tool" => tool} -> tool
      _ -> ""
    end
  end

  defp transition_work_item(conn, work_item_id, from, to, env) do
    placeholders = from |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")

    Store.query(
      conn,
      "UPDATE WORK_ITEMS SET state = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND state IN (#{placeholders}) AND last_sequence < ?",
      [to, env.occurred_at, env.sequence, work_item_id] ++ from ++ [env.sequence]
    )
  end
end
