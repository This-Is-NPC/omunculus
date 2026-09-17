defmodule Omunculus.Store.Runs do
  @moduledoc """
  Harness-side writes of the run cycle (spec §3.2, §3.3, §8.7): `begin/2`
  inserts the run and `start-run` without a prompt, `attach_assembled/3`
  stores `PROMPTS(assembled)` and fills `prompt_id` once, `open/2`
  is begin-then-attach for tests, `record_model/3` logs a model
  turn, `record_tool/5` logs a call and applies its emits as one
  transaction so a failed emit leaves no stray `tool` event, `close/2`
  ends the run.
  """

  alias Omunculus.Id
  alias Omunculus.Store.{Actions, Events, Query}

  @spec begin(Exqlite.Sqlite3.db(), map) :: {:ok, map} | {:error, term}
  def begin(conn, params) do
    Query.transaction(conn, fn -> do_begin(conn, params) end)
  end

  @spec attach_assembled(Exqlite.Sqlite3.db(), String.t(), String.t()) ::
          {:ok, map} | {:error, term}
  def attach_assembled(conn, run_id, body) do
    Query.transaction(conn, fn -> do_attach(conn, run_id, body) end)
  end

  @spec open(Exqlite.Sqlite3.db(), map) :: {:ok, map} | {:error, term}
  def open(conn, params) do
    assembled = Map.fetch!(params, :assembled)

    with {:ok, run} <- begin(conn, params),
         do: attach_assembled(conn, run.id, assembled)
  end

  @spec record_model(Exqlite.Sqlite3.db(), String.t(), String.t()) :: {:ok, map} | {:error, term}
  def record_model(conn, run_id, text) do
    Query.transaction(conn, fn ->
      Events.append(conn, %{type: "model", run_id: run_id, body: text})
    end)
  end

  @spec record_tool(Exqlite.Sqlite3.db(), String.t() | nil, map, [map], map) ::
          {:ok, [map]} | {:error, term}
  def record_tool(conn, run_id, call, emits, ctx) do
    Query.transaction(conn, fn ->
      with {:ok, tool_event} <-
             Events.append(conn, %{
               type: "tool",
               run_id: run_id,
               work_id: ctx.work_id,
               request_id: Map.get(ctx, :request_id),
               inbox_id: Map.get(ctx, :inbox_id),
               body: Jason.encode!(call)
             }),
           {:ok, emit_events} <- Actions.run(conn, emits, ctx) do
        {:ok, [tool_event | emit_events]}
      end
    end)
  end

  @spec close(Exqlite.Sqlite3.db(), String.t()) :: {:ok, map} | {:error, term}
  def close(conn, run_id) do
    Query.transaction(conn, fn -> do_close(conn, run_id) end)
  end

  defp do_begin(conn, params) do
    run_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "start-run",
             run_id: run_id,
             prompt_id: params.prompt_id,
             work_id: params.work_id,
             request_id: params.request_id,
             inbox_id: Map.get(params, :inbox_id),
             body:
               Jason.encode!(%{
                 agent: params.agent,
                 depth: params.depth,
                 ceiling: params.ceiling,
                 execution: params.execution
               })
           }),
         :ok <-
           Query.insert(conn, :runs, %{
             id: run_id,
             work_id: params.work_id,
             prompt_id: nil,
             event_id: event.id,
             agent: params.agent,
             depth: to_string(params.depth),
             via: params.via,
             request_id: params.request_id,
             tools: Jason.encode!(Map.get(params, :tools, params.ceiling.have)),
             status: "open",
             started_at: event.at
           }),
         :ok <- link_message(conn, params.prompt_id, run_id) do
      Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
    end
  end

  defp do_attach(conn, run_id, body) do
    assembled_id = Id.new()

    with {:ok, run} <- Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id]),
         :ok <- attachable_run(run),
         {:ok, event} <- Query.one(conn, "SELECT * FROM events WHERE id = ?", [run.event_id]),
         :ok <-
           Query.insert(conn, :prompts, %{
             id: assembled_id,
             kind: "assembled",
             body: body,
             run_id: run_id,
             created_at: event.at
           }),
         :ok <-
           Query.exec(conn, "UPDATE runs SET prompt_id = ? WHERE id = ?", [assembled_id, run_id]) do
      Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
    end
  end

  defp attachable_run(%{status: "open", prompt_id: nil}), do: :ok
  defp attachable_run(_run), do: {:error, {:run, :not_open}}

  defp link_message(_conn, nil, _run_id), do: :ok

  defp link_message(conn, prompt_id, run_id),
    do: Query.exec(conn, "UPDATE prompts SET run_id = ? WHERE id = ?", [run_id, prompt_id])

  defp do_close(conn, run_id) do
    with {:ok, run} <- Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id]) do
      close_open_run(conn, run)
    end
  end

  defp close_open_run(_conn, %{status: status}) when status != "open",
    do: {:error, {:run, :not_open}}

  defp close_open_run(_conn, nil), do: {:error, {:run, :not_open}}

  defp close_open_run(conn, run) do
    with :ok <-
           Query.exec(conn, "UPDATE runs SET status = 'done', finished_at = ? WHERE id = ?", [
             Events.now(),
             run.id
           ]) do
      Events.append(conn, %{type: "end-run", run_id: run.id, body: "{}"})
    end
  end
end
