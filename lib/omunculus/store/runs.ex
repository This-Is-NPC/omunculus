defmodule Omunculus.Store.Runs do
  @moduledoc """
  Harness-side writes of the run cycle (spec §3.2, §3.3, §8.7): `begin/2`
  inserts the run and `start-run` without a prompt, `attach_assembled/3`
  stores `PROMPTS(assembled)` and fills `prompt_id` once, `record_model/3`
  logs a model turn, `record_tools/4` logs a call and the steps it
  chained, each followed by its emits, as one transaction so a failed
  emit leaves no stray `tool` event, `close/2` ends the run. `begin/2`
  refuses a run of a cancelled work, and a work's own run (`own`, no
  named agent) of a work that is not open. `unreported/5` decides in one transaction what follows a
  closed run whose model stopped without `end` on a work still open:
  another run while the work's latest runs without `end` are within
  `max_retries`; past it, a `break` with the given text for a child,
  or, for a root, a request by the harness with the options `retry` and
  `cancel` and an inbox entry whose text names the new request.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Actions, Connection, Events, Query, View}

  @spec begin(Connection.t(), map) :: {:ok, map} | {:error, term}
  def begin(conn, params) do
    Query.transaction(conn, fn -> do_begin(conn, params) end)
  end

  @spec attach_assembled(Connection.t(), String.t(), String.t()) ::
          {:ok, map} | {:error, term}
  def attach_assembled(conn, run_id, body) do
    Query.transaction(conn, fn -> do_attach(conn, run_id, body) end)
  end

  @spec record_model(Connection.t(), String.t(), String.t()) :: {:ok, map} | {:error, term}
  def record_model(conn, run_id, text) do
    Query.transaction(conn, fn ->
      Events.append(conn, %{type: "model", run_id: run_id, body: text})
    end)
  end

  @spec record_tools(Connection.t(), String.t() | nil, [{map, [map]}], map) ::
          {:ok, [map]} | {:error, term}
  def record_tools(conn, run_id, calls, ctx) do
    Query.transaction(conn, fn ->
      Enum.reduce_while(calls, {:ok, []}, fn {call, emits}, {:ok, acc} ->
        case record_call(conn, run_id, call, emits, ctx) do
          {:ok, events} -> {:cont, {:ok, acc ++ events}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end)
  end

  defp record_call(conn, run_id, call, emits, ctx) do
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
  end

  @spec close(Connection.t(), String.t()) :: {:ok, map} | {:error, term}
  def close(conn, run_id) do
    Query.transaction(conn, fn -> do_close(conn, run_id) end)
  end

  @spec unreported(
          Connection.t(),
          map,
          non_neg_integer,
          (pos_integer -> String.t()),
          (String.t(), String.t(), [String.t()] -> String.t())
        ) :: {:ok, :retry | :none | {:stopped, [map]}} | {:error, term}
  def unreported(conn, run, max_retries, reason_text, inbox_text) do
    Query.transaction(conn, fn ->
      with {:ok, work} <- Helpers.fetch_work(conn, run.work_id) do
        case {work.state, View.unended_runs(conn, work.id)} do
          {"open", runs} when runs > max_retries ->
            with {:ok, events} <- stop_work(conn, run, work, reason_text.(runs), inbox_text),
                 do: {:ok, {:stopped, events}}

          {"open", runs} when runs > 0 ->
            {:ok, :retry}

          _reported_or_parked ->
            {:ok, :none}
        end
      end
    end)
  end

  defp stop_work(conn, run, %{parent_id: nil}, text, inbox_text) do
    ctx = %{run_id: run.id, work_id: run.work_id, author: "harness", agent: run.agent}
    options = %{"retry" => [], "cancel" => [%{"name" => "cancel"}]}
    body = %{"reason" => text, "options" => options}

    with {:ok, [request]} <- Actions.run(conn, [%{"type" => "request", "body" => body}], ctx),
         inbox = inbox_text.(request.request_id, text, Map.keys(options)),
         notify = %{"body" => inbox, "work_id" => run.work_id},
         {:ok, inbox} <- Actions.run(conn, [%{"type" => "notify", "body" => notify}], ctx) do
      {:ok, [request | inbox]}
    end
  end

  defp stop_work(conn, run, _child, text, _inbox_text) do
    ctx = %{run_id: run.id, work_id: run.work_id, author: "agent", agent: run.agent}
    Actions.run(conn, [%{"type" => "break", "body" => %{"body" => text}}], ctx)
  end

  defp do_begin(conn, params) do
    run_id = Id.new()

    with :ok <- runnable(conn, params.work_id, Map.get(params, :own, false)),
         {:ok, event} <-
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
             tools: Jason.encode!(params.tools),
             status: "open",
             started_at: event.at
           }),
         :ok <- link_message(conn, params.prompt_id, run_id) do
      View.view(conn, "run", run_id)
    end
  end

  # A cancelled work opens no run; a work's own run (no named agent)
  # opens only while the work is open.
  defp runnable(_conn, nil, _own), do: :ok

  defp runnable(conn, work_id, own) do
    case Helpers.fetch_work(conn, work_id) do
      {:ok, %{state: "cancelled"}} -> {:error, {:cancelled, work_id}}
      {:ok, %{state: "open"}} -> :ok
      {:ok, _not_open} when own -> {:error, {:not_open, work_id}}
      {:ok, _work} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp do_attach(conn, run_id, body) do
    assembled_id = Id.new()

    with {:ok, run} <- View.view(conn, "run", run_id),
         :ok <- attachable_run(run),
         {:ok, event} <- View.view(conn, "event", run.event_id),
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
      View.view(conn, "run", run_id)
    end
  end

  defp attachable_run(%{status: "open", prompt_id: nil}), do: :ok
  defp attachable_run(_run), do: {:error, {:run, :not_open}}

  defp link_message(_conn, nil, _run_id), do: :ok

  defp link_message(conn, prompt_id, run_id),
    do: Query.exec(conn, "UPDATE prompts SET run_id = ? WHERE id = ?", [run_id, prompt_id])

  defp do_close(conn, run_id) do
    with {:ok, run} <- View.view(conn, "run", run_id) do
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
