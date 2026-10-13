defmodule Omunculus.Store.Runs do
  @moduledoc """
  Harness-side writes of the run cycle (spec §3.2, §3.3, §8.7): `begin/2`
  inserts the run and `start-run` without a prompt, `attach_assembled/3`
  stores `PROMPTS(assembled)` and fills `prompt_id` once, `record_model/3`
  logs a model turn, `record_tools/4` logs a call and the steps it
  chained, each followed by its emits, as one transaction so a failed
  emit leaves no stray `tool` event, `close/2` ends the run. `begin/2`
  refuses a run of a cancelled work, and a work's own run (`own`, no
  named agent) of a work that is not open. `unreported/6` decides in one transaction what follows a
  closed run whose model stopped without `end` on a work still open:
  another run while the work's latest runs without `end` are within
  `max_retries`; past it, a `break` with the given text for a child,
  or, for a root, a request by the harness with the options `retry` and
  `cancel` and an inbox note saying how to answer it; their texts name the
  agent and the work's title.
  `continues/3` records the `session` event of a run that continues its
  agent's session: the run it continues and what it was told had happened.
  `uncaused/1` lists the events that may ask for a run and that no run
  began for, each with the name of the call that emitted it as `via`;
  `begun?/3` says whether an opening due for one of them began: a run it
  caused, or for a work's own run, any own run of the work begun after it,
  into which a run due while it waited was merged. `runnable/2` is the
  check `begin/2` makes. `stopped/1` lists the own runs whose model
  stopped without `end` on a work still open and that no own run of the
  work followed: their retry, or what follows it, was never decided or
  never began.
  `left/1` lists the closed runs that left a request pending at their
  agent: each pending request's last run of its receiver opened for it or
  for a request it was escalated into, unless an answer to that request
  came after it began, whose run resumes the receiver.
  `unanswered/4` uses the linked escalation action when an agent receiver
  closes without answering, or an intermediary resumed by a text answer
  closes leaving pending the origins it returned, its reason naming the agent and each question
  it held, shortened, with who asked it and the title of their work. When the new request reaches a
  human it records an inbox note saying so, in the same transaction.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Access
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Actions, Connection, Events, Query, View}

  @spec open_runs(Connection.t()) :: {:ok, [map]} | {:error, term}
  def open_runs(conn),
    do: Query.all(conn, "SELECT * FROM runs WHERE status = 'open' ORDER BY started_at, id")

  @spec uncaused(Connection.t()) :: {:ok, [map]} | {:error, term}
  def uncaused(conn) do
    Query.all(
      conn,
      """
      SELECT events.*, (
        SELECT json_extract(call.body, '$.name') FROM events AS call
        WHERE call.type = 'tool' AND call.run_id IS events.run_id
          AND call.sequence < events.sequence
        ORDER BY call.sequence DESC LIMIT 1) AS via
      FROM events
      WHERE events.type IN
          ('prompt', 'reply', 'continue', 'break', 'cancel', 'delegate', 'reopen', 'request', 'work')
        AND NOT EXISTS (SELECT 1 FROM runs WHERE runs.cause_id = events.id)
      ORDER BY events.sequence
      """
    )
  end

  @spec begun?(Connection.t(), map, map) :: boolean
  def begun?(conn, %{agent: nil, work_id: work_id}, event) when is_binary(work_id) do
    {:ok, [%{begun: begun}]} =
      Query.all(
        conn,
        """
        SELECT EXISTS (
          SELECT 1 FROM runs JOIN events AS start ON start.id = runs.event_id
          WHERE runs.work_id = ? AND start.sequence > ?
            AND json_extract(start.body, '$.own')) AS begun
        """,
        [work_id, event.sequence]
      )

    begun == 1
  end

  def begun?(conn, _named, event) do
    {:ok, [%{begun: begun}]} =
      Query.all(conn, "SELECT EXISTS (SELECT 1 FROM runs WHERE cause_id = ?) AS begun", [
        event.id
      ])

    begun == 1
  end

  @spec stopped(Connection.t()) :: {:ok, [map]} | {:error, term}
  def stopped(conn) do
    Query.all(
      conn,
      """
      SELECT runs.* FROM runs
      JOIN events AS start ON start.id = runs.event_id
      JOIN works ON works.id = runs.work_id
      WHERE runs.status = 'done' AND works.state = 'open'
        AND json_extract(start.body, '$.own')
        AND NOT EXISTS (SELECT 1 FROM events WHERE events.run_id = runs.id AND events.type = 'end')
        AND NOT EXISTS (
          SELECT 1 FROM runs AS later JOIN events AS later_start ON later_start.id = later.event_id
          WHERE later.work_id = runs.work_id AND later_start.sequence > start.sequence
            AND json_extract(later_start.body, '$.own'))
      ORDER BY start.sequence
      """
    )
  end

  @spec left(Connection.t()) :: {:ok, [map]} | {:error, term}
  def left(conn) do
    Query.all(
      conn,
      """
      SELECT DISTINCT runs.* FROM requests
      JOIN runs ON runs.id = (
        SELECT held.id FROM runs AS held
        WHERE held.agent = json_extract(requests.arbiter, '$.agent')
          AND (held.request_id = requests.id OR held.request_id IN (
            SELECT escalated_id FROM request_escalations WHERE origin_id = requests.id))
        ORDER BY held.started_at DESC, held.id DESC
        LIMIT 1)
      JOIN events AS start ON start.id = runs.event_id
      WHERE requests.status = 'pending'
        AND json_extract(requests.arbiter, '$.kind') = 'agent'
        AND runs.status = 'done'
        AND NOT EXISTS (
          SELECT 1 FROM events AS answer
          WHERE answer.type = 'reply' AND answer.sequence > start.sequence
            AND answer.request_id IN (
              SELECT escalated_id FROM request_escalations WHERE origin_id = requests.id))
      ORDER BY runs.started_at, runs.id
      """
    )
  end

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
      Events.append(conn, %{type: "model", actor_kind: "agent", run_id: run_id, body: text})
    end)
  end

  @spec record_tools(Connection.t(), String.t() | nil, [{map, [map]}], map) ::
          {:ok, [map]} | {:error, term}
  def record_tools(conn, run_id, calls, ctx) do
    Query.transaction(conn, fn ->
      with {:ok, events} <-
             Enum.reduce_while(calls, {:ok, []}, fn {call, emits}, {:ok, acc} ->
               case record_call(conn, run_id, call, emits, ctx) do
                 {:ok, events} -> {:cont, {:ok, acc ++ events}}
                 {:error, _reason} = error -> {:halt, error}
               end
             end),
           :ok <- record_receipt(conn, ctx, calls, events) do
        {:ok, events}
      end
    end)
  end

  defp record_receipt(conn, ctx, calls, events) do
    case Map.get(ctx, :command_id) do
      nil ->
        :ok

      command_id ->
        last = List.last(events)

        Query.insert(conn, :command_receipts, %{
          issuer: ctx.issuer,
          subject: ctx.subject,
          command_id: command_id,
          operation: ctx.command_hash,
          result:
            Jason.encode!(%{
              cursor: last && last.sequence,
              ok: calls |> hd() |> elem(0) |> Map.fetch!(:ok)
            }),
          created_at: Events.now()
        })
    end
  end

  defp record_call(conn, run_id, call, emits, ctx) do
    with :ok <- authorize_human(conn, ctx),
         {:ok, tool_event} <-
           Events.append(conn, %{
             type: "tool",
             actor_kind: Map.get(ctx, :author),
             actor_id: Map.get(ctx, :agent),
             run_id: run_id,
             conversation_id: Map.get(ctx, :conversation_id),
             actor_issuer: Map.get(ctx, :issuer),
             actor_subject: Map.get(ctx, :subject),
             work_id: ctx.work_id,
             request_id: Map.get(ctx, :request_id),
             inbox_id: Map.get(ctx, :inbox_id),
             body: Jason.encode!(call)
           }),
         {:ok, emit_events} <- Actions.run(conn, emits, ctx) do
      {:ok, [tool_event | emit_events]}
    end
  end

  defp authorize_human(_conn, ctx) when not is_map_key(ctx, :principal), do: :ok
  defp authorize_human(_conn, %{principal: nil}), do: :ok

  defp authorize_human(conn, %{principal: principal, capability: capability} = ctx) do
    Access.check(conn, ctx.config.access, principal, capability, ctx.conversation_id)
  end

  @doc "Closes an open run; its `end-run` carries `error`, why its model failed, when given."
  @spec close(Connection.t(), String.t(), String.t() | nil) :: {:ok, map} | {:error, term}
  def close(conn, run_id, error \\ nil) do
    Query.transaction(conn, fn -> do_close(conn, run_id, error) end)
  end

  @spec unreported(
          Connection.t(),
          map,
          non_neg_integer,
          (pos_integer, String.t(), String.t() -> String.t()),
          (String.t(), [String.t()] -> String.t()),
          map
        ) :: {:ok, :retry | :none | {:stopped, [map]}} | {:error, term}
  def unreported(conn, run, max_retries, reason_text, inbox_text, config) do
    Query.transaction(conn, fn ->
      with {:ok, work} <- Helpers.fetch_work(conn, run.work_id) do
        case {work.state, View.unended_runs(conn, work.id)} do
          {"open", runs} when runs > max_retries ->
            text = reason_text.(runs, run.agent, work.title)

            with {:ok, events} <- stop_work(conn, run, work, text, inbox_text, config),
                 do: {:ok, {:stopped, events}}

          {"open", runs} when runs > 0 ->
            {:ok, :retry}

          _reported_or_parked ->
            {:ok, :none}
        end
      end
    end)
  end

  @spec continues(Connection.t(), String.t(), map) :: :ok | {:error, term}
  def continues(conn, run_id, body) do
    with {:ok, _event} <-
           Events.append(conn, %{type: "session", run_id: run_id, body: Jason.encode!(body)}),
         do: :ok
  end

  @spec unanswered(Connection.t(), map, map, (String.t(), [map], boolean -> String.t())) ::
          {:ok, [map]} | {:error, term}
  def unanswered(_conn, %{request_id: nil}, _config, _reason_text), do: {:ok, []}

  def unanswered(conn, run, config, reason_text) do
    Query.transaction(conn, fn ->
      with {:ok, request} <- View.view(conn, "request", run.request_id) do
        case left(request, Omunculus.Participant.agent(run.agent)) do
          [] -> {:ok, []}
          parts -> pass_on(conn, run, config, reason_text, parts)
        end
      end
    end)
  end

  # What a run of `receiver` leaves pending: the request it was opened
  # for, or, once that was answered, the origins the answer returned to it.
  defp left(request, receiver) do
    if held?(request, receiver),
      do: [{"answer", request}],
      else: request.origins |> Enum.filter(fn {_part, origin} -> held?(origin, receiver) end)
  end

  defp held?(request, receiver),
    do: request.status == "pending" and Jason.decode!(request.arbiter) == receiver

  defp pass_on(conn, run, config, reason_text, parts) do
    ctx = %{
      run_id: run.id,
      work_id: run.work_id,
      author: "harness",
      agent: run.agent,
      config: config,
      groups: %{}
    }

    with {:ok, questions} <- questions(conn, parts),
         text = &reason_text.(run.agent, questions, &1),
         {:ok, events} <-
           Actions.run(
             conn,
             [
               %{
                 "type" => "escalate",
                 "body" => %{
                   "reason" => text.(false),
                   "origins" => Map.new(parts, fn {part, request} -> {part, request.id} end)
                 }
               }
             ],
             ctx
           ),
         upstream = Enum.find(events, &(&1.type == "request")),
         {:ok, linked} <- View.view(conn, "request", upstream.request_id),
         {:ok, notified} <- notify_unanswered(conn, linked, ctx, text.(true)) do
      {:ok, events ++ notified}
    end
  end

  # The questions the requests of `parts` hold: each its own, or those of
  # the requests it links, with who asked it and the title of the asker's work.
  defp questions(conn, parts) do
    parts
    |> Enum.sort()
    |> Enum.flat_map(fn {_part, request} -> asked(request) end)
    |> Enum.reduce_while({:ok, []}, fn asked, {:ok, acc} ->
      case title(conn, asked.work_id) do
        {:ok, title} ->
          question = %{requester: asked.requester, reason: asked.reason, title: title}
          {:cont, {:ok, acc ++ [question]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp asked(%{origins: origins} = request) when map_size(origins) == 0, do: [request]

  defp asked(%{origins: origins}),
    do: origins |> Enum.sort() |> Enum.flat_map(fn {_part, origin} -> asked(origin) end)

  defp title(_conn, nil), do: {:ok, nil}

  defp title(conn, work_id) do
    with {:ok, work} <- Helpers.fetch_work(conn, work_id), do: {:ok, work.title}
  end

  defp notify_unanswered(conn, request, ctx, note) do
    if Jason.decode!(request.arbiter)["kind"] == "human" do
      Actions.run(
        conn,
        [%{"type" => "notify", "body" => %{"body" => note, "work_id" => request.work_id}}],
        ctx
      )
    else
      {:ok, []}
    end
  end

  defp stop_work(conn, run, %{parent_id: nil}, text, inbox_text, config) do
    ctx = %{
      run_id: run.id,
      work_id: run.work_id,
      author: "harness",
      agent: run.agent,
      config: config,
      groups: %{}
    }

    options = %{"retry" => [], "cancel" => [%{"name" => "cancel"}]}
    body = %{"reason" => text, "options" => options}

    with {:ok, [request]} <- Actions.run(conn, [%{"type" => "request", "body" => body}], ctx),
         inbox = inbox_text.(text, Map.keys(options)),
         notify = %{"body" => inbox, "work_id" => run.work_id},
         {:ok, inbox} <- Actions.run(conn, [%{"type" => "notify", "body" => notify}], ctx) do
      {:ok, [request | inbox]}
    end
  end

  defp stop_work(conn, run, _child, text, _inbox_text, _config) do
    ctx = %{run_id: run.id, work_id: run.work_id, author: "agent", agent: run.agent}
    Actions.run(conn, [%{"type" => "break", "body" => %{"body" => text}}], ctx)
  end

  defp do_begin(conn, params) do
    run_id = Id.new()

    with :ok <- runnable(conn, params),
         {:ok, event} <-
           Events.append(conn, %{
             type: "start-run",
             actor_kind: "harness",
             conversation_id: Map.get(params, :conversation_id),
             origin_issuer: Map.get(params, :origin_issuer),
             origin_subject: Map.get(params, :origin_subject),
             run_id: run_id,
             prompt_id: params.prompt_id,
             work_id: params.work_id,
             request_id: params.request_id,
             inbox_id: Map.get(params, :inbox_id),
             body:
               Jason.encode!(%{
                 agent: params.agent,
                 depth: params.depth,
                 own: Map.get(params, :own, false),
                 ceiling: params.ceiling,
                 execution: params.execution
               })
           }),
         :ok <-
           Query.insert(conn, :runs, %{
             id: run_id,
             conversation_id: Map.get(params, :conversation_id),
             origin_issuer: Map.get(params, :origin_issuer),
             origin_subject: Map.get(params, :origin_subject),
             work_id: params.work_id,
             prompt_id: nil,
             event_id: event.id,
             agent: params.agent,
             depth: to_string(params.depth),
             via: params.via,
             request_id: params.request_id,
             cause_id: Map.get(params, :cause_id),
             tools: Jason.encode!(params.tools),
             status: "open",
             started_at: event.at
           }),
         :ok <- link_message(conn, params.prompt_id, run_id) do
      View.view(conn, "run", run_id)
    end
  end

  @spec runnable(Connection.t(), map) :: :ok | {:error, term}
  def runnable(conn, params) do
    with :ok <- runnable_work(conn, params.work_id, Map.get(params, :own, false)),
         do: runnable_request(conn, params)
  end

  defp runnable_request(conn, %{cause_id: cause_id, request_id: request_id, agent: agent})
       when is_binary(cause_id) and is_binary(request_id) do
    with {:ok, cause} <- View.view(conn, "event", cause_id),
         {:ok, request} <- View.view(conn, "request", request_id) do
      if cause.type == "request" and
           (request.status != "pending" or
              Jason.decode!(request.arbiter) != Omunculus.Participant.agent(agent)),
         do: {:error, {:not_open, request_id}},
         else: :ok
    end
  end

  defp runnable_request(_conn, _params), do: :ok

  # A cancelled work opens no run; a work's own run (no named agent)
  # opens only while the work is open.
  defp runnable_work(_conn, nil, _own), do: :ok

  defp runnable_work(conn, work_id, own) do
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
             conversation_id: run.conversation_id,
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

  defp do_close(conn, run_id, error) do
    with {:ok, run} <- View.view(conn, "run", run_id) do
      close_open_run(conn, run, error)
    end
  end

  defp close_open_run(_conn, %{status: status}, _error) when status != "open",
    do: {:error, {:run, :not_open}}

  defp close_open_run(_conn, nil, _error), do: {:error, {:run, :not_open}}

  defp close_open_run(conn, run, error) do
    with :ok <-
           Query.exec(conn, "UPDATE runs SET status = 'done', finished_at = ? WHERE id = ?", [
             Events.now(),
             run.id
           ]) do
      body = if error, do: %{error: error}, else: %{}

      Events.append(conn, %{
        type: "end-run",
        actor_kind: "harness",
        run_id: run.id,
        body: Jason.encode!(body)
      })
    end
  end
end
