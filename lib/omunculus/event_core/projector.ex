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
            apply_event(conn, env)
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

  defp apply_event(conn, %{type: "task.requested"} = env) do
    p = env.payload
    workspace_id = p["workspace"]

    Store.query(
      conn,
      "INSERT OR IGNORE INTO WORK_ITEMS (work_item_id, project_id, workspace_id, parent_work_item_id, instruction, status, version, created_at, updated_at, last_sequence) VALUES (?, ?, ?, NULL, ?, 'requested', 0, ?, ?, ?)",
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
      "INSERT OR IGNORE INTO WORK_ITEMS (work_item_id, project_id, parent_work_item_id, instruction, status, version, created_at, updated_at, last_sequence) VALUES (?, ?, ?, ?, 'requested', 0, ?, ?, ?)",
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

    child_workspace = p["workspace"] || env.workspace_id

    if child_workspace do
      Store.query(
        conn,
        "UPDATE WORK_ITEMS SET workspace_id = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
        [child_workspace, env.sequence, child, env.sequence]
      )
    end

    transition_work_item(conn, env.work_item_id, ["running", "requested"], "waiting", env)
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

    transition_work_item(
      conn,
      env.work_item_id,
      ["requested", "failed", "waiting"],
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

  defp apply_event(conn, %{type: "model.call.completed"} = env) do
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
        p["outcome"],
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
        "UPDATE WORK_ITEMS SET status = 'completed', result = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND status IN ('running', 'waiting') AND last_sequence < ?",
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
    outcome = p["outcome"] || "completed"

    Store.query(
      conn,
      "UPDATE ARCHIVE_RUNS SET status = ?, outcome = ?, finished_at = ?, last_sequence = ? WHERE run_id = ? AND status = 'running' AND last_sequence < ?",
      [outcome, outcome, env.occurred_at, env.sequence, env.run_id, env.sequence]
    )

    case outcome do
      "waiting" ->
        Store.query(
          conn,
          "UPDATE WORK_ITEMS SET status = 'waiting', awaiting = ?, checkpoint = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
          [
            Jason.encode!(p["awaiting"] || []),
            Jason.encode!(p["checkpoint"] || %{}),
            env.occurred_at,
            env.sequence,
            env.work_item_id,
            env.sequence
          ]
        )

      "completed" ->
        Store.query(
          conn,
          "UPDATE WORK_ITEMS SET awaiting = NULL, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND last_sequence < ?",
          [env.occurred_at, env.sequence, env.work_item_id, env.sequence]
        )

      _ ->
        :ok
    end
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

  # Commands and events without a projection effect (tool.call.requested,
  # task.resumed, ...) are still consumed: the cursor advances past them.
  defp apply_event(_conn, _env), do: :ok

  defp transition_work_item(conn, work_item_id, from, to, env) do
    placeholders = from |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")

    Store.query(
      conn,
      "UPDATE WORK_ITEMS SET status = ?, version = version + 1, updated_at = ?, last_sequence = ? WHERE work_item_id = ? AND status IN (#{placeholders}) AND last_sequence < ?",
      [to, env.occurred_at, env.sequence, work_item_id] ++ from ++ [env.sequence]
    )
  end
end
