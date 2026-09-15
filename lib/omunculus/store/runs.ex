defmodule Omunculus.Store.Runs do
  @moduledoc """
  Harness-side writes of the run cycle (spec §3.2, §3.3, §8.7): `open/2`
  starts a run from an assembled prompt, `record_model/3` logs a model
  turn, `record_tool/5` logs a call and applies its emits as one
  transaction so a failed emit leaves no stray `tool` event, `close/2`
  ends the run.
  """

  alias Omunculus.Id
  alias Omunculus.Store.{Actions, Events, Query}

  @spec open(Exqlite.Sqlite3.db(), map) :: {:ok, map} | {:error, term}
  def open(conn, params) do
    Query.transaction(conn, fn -> do_open(conn, params) end)
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

  defp do_open(conn, params) do
    run_id = Id.new()
    assembled_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "start-run",
             run_id: run_id,
             prompt_id: params.prompt_id,
             body:
               Jason.encode!(%{
                 agent: params.agent,
                 depth: params.depth,
                 ceiling: params.ceiling
               })
           }),
         :ok <-
           Query.insert(conn, :prompts, %{
             id: assembled_id,
             kind: "assembled",
             body: params.assembled,
             run_id: run_id,
             created_at: event.at
           }),
         :ok <-
           Query.insert(conn, :runs, %{
             id: run_id,
             work_id: params.work_id,
             prompt_id: assembled_id,
             event_id: event.id,
             agent: params.agent,
             depth: to_string(params.depth),
             via: params.via,
             request_id: params.request_id,
             tools: Jason.encode!(params.ceiling.have),
             status: "open",
             started_at: event.at
           }),
         :ok <- link_message(conn, params.prompt_id, run_id) do
      Query.one(conn, "SELECT * FROM runs WHERE id = ?", [run_id])
    end
  end

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
