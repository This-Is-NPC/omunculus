defmodule Omunculus.Store.Actions do
  @moduledoc """
  Write side of the store: `run/3` applies the emits from a tool's
  `out.emit` in order, inside whatever transaction the caller holds — the
  whole batch commits or nothing does (spec §8.3). `work` creates a root
  work with the `report` as its first comment, links the run to it when
  the run has no work yet, and marks it to start. `work` and `delegate`
  may name the new work's `agent`: one of the TOML's agents at its depth
  that is not `workflow_only`, refused when that depth has a workflow;
  unnamed, it is the first stage's agent or the depth's first agent.
  `continue`, `break`, `delegate`, `cancel` and `end` are
  dispatched to `Actions.Sequence`; `request`, `reply` and `grant` to
  `Actions.Requests`; `notify` and `inbox.read` to `Actions.Inbox`;
  `compact` and `comment.delete` to `Actions.Comments`.
  """

  alias Omunculus.Id
  alias Omunculus.Store.Actions.{Comments, Contract, Helpers, Inbox, Requests, Sequence}
  alias Omunculus.Store.{Events, Query}

  @comment_targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}

  @spec run(Omunculus.Store.Connection.t(), [map], map) :: {:ok, [map]} | {:error, term}
  def run(conn, emits, ctx) do
    emits
    |> Enum.reduce_while({:ok, []}, fn emit, {:ok, events} ->
      case with(:ok <- Contract.validate(emit), do: dispatch(conn, emit, ctx)) do
        {:ok, result} -> {:cont, {:ok, [result | events]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, events |> Enum.reverse() |> List.flatten() |> Enum.reject(&is_nil/1)}
      error -> error
    end
  end

  defp dispatch(conn, %{"type" => "comment"} = emit, ctx),
    do: comment(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "prompt"} = emit, _ctx),
    do: prompt(conn, Map.get(emit, "body", %{}))

  defp dispatch(conn, %{"type" => "work"} = emit, ctx),
    do: work(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "request"} = emit, ctx),
    do: Requests.request(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "reply"} = emit, ctx),
    do: Requests.reply(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "grant"} = emit, ctx),
    do: Requests.grant(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "cancel"} = emit, ctx),
    do: Sequence.cancel(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "continue"} = emit, ctx),
    do: Sequence.continue(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "break"} = emit, ctx),
    do: Sequence.break(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "delegate"} = emit, ctx),
    do: Sequence.delegate(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "end"}, ctx), do: Sequence.end_run(conn, ctx)

  defp dispatch(conn, %{"type" => "notify"} = emit, ctx),
    do: Inbox.notify(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "inbox.read"} = emit, ctx),
    do: Inbox.read(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "compact"} = emit, ctx),
    do: Comments.compact(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "comment.delete"} = emit, ctx),
    do: Comments.delete(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(_conn, %{"type" => type}, _ctx), do: {:error, {:unknown_action, type}}

  defp comment(conn, body, ctx) do
    targets =
      Map.new(@comment_targets, fn {key, table} -> {table, Map.get(body, key)} end)

    with :ok <- ensure_text(body),
         :ok <- ensure_target(targets),
         :ok <- Helpers.tag_error(:comment, Helpers.ensure_exist(conn, Map.to_list(targets))) do
      write_comment(conn, body, targets, ctx)
    end
  end

  defp ensure_text(%{"body" => text}) when is_binary(text) and text != "", do: :ok
  defp ensure_text(_body), do: {:error, {:comment, :no_body}}

  defp ensure_target(targets) do
    if Enum.any?(targets, fn {_table, id} -> not is_nil(id) end) do
      :ok
    else
      {:error, {:comment, :no_target}}
    end
  end

  defp write_comment(conn, body, targets, ctx) do
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "comment",
             comment_id: comment_id,
             run_id: ctx.run_id,
             work_id: targets.works,
             request_id: targets.requests,
             inbox_id: targets.inbox,
             body: Jason.encode!(body)
           }),
         :ok <- Helpers.insert_comment(conn, comment_id, targets, body["body"], event, ctx) do
      {:ok, event}
    end
  end

  defp prompt(conn, %{"message" => text} = body) when is_binary(text) and text != "" do
    with :ok <-
           Helpers.tag_error(:prompt, Helpers.ensure_exist(conn, [{:works, body["work_id"]}])),
         {:ok, reopened} <- reopen_waiting_work(conn, body["work_id"]),
         {:ok, prompt_event} <- write_prompt(conn, body, text) do
      {:ok, Enum.reject([reopened, prompt_event], &is_nil/1)}
    end
  end

  defp prompt(_conn, _body), do: {:error, {:prompt, :no_message}}

  defp reopen_waiting_work(_conn, nil), do: {:ok, nil}

  defp reopen_waiting_work(conn, work_id) do
    with {:ok, work} <- Query.one(conn, "SELECT state FROM works WHERE id = ?", [work_id]) do
      case work do
        %{state: "waiting"} ->
          with :ok <- Helpers.reopen_work(conn, work_id) do
            Events.append(conn, %{
              type: "work",
              work_id: work_id,
              body: Jason.encode!(%{state: "open", reason: "reopened_by_prompt"})
            })
          end

        _other ->
          {:ok, nil}
      end
    end
  end

  defp write_prompt(conn, body, text) do
    prompt_id = Id.new()

    with :ok <-
           Query.insert(conn, :prompts, %{
             id: prompt_id,
             kind: "message",
             body: text,
             run_id: nil,
             created_at: Events.now()
           }) do
      Events.append(conn, %{
        type: "prompt",
        prompt_id: prompt_id,
        work_id: body["work_id"],
        body: Jason.encode!(body)
      })
    end
  end

  defp work(conn, body, ctx) do
    with :ok <- Helpers.ensure_no_forbidden(:work, body),
         :ok <- Helpers.ensure_title(:work, body),
         :ok <- Helpers.ensure_goal(:work, body),
         :ok <- ensure_report(body),
         {:ok, {stage, assignee}} <-
           Helpers.tag_error(
             :work,
             Helpers.stage_and_assignee(ctx.config, 0, body["agent"])
           ),
         {:ok, workspace} <-
           Helpers.tag_error(:work, Helpers.resolve_workspace(ctx.config, body["workspace"], nil)) do
      create_root(conn, body, ctx, stage, assignee, workspace)
    end
  end

  defp ensure_report(%{"report" => report}) when is_binary(report) and report != "", do: :ok
  defp ensure_report(_body), do: {:error, {:work, :no_report}}

  # The root's run opens once the run that created it has ended.
  defp create_root(conn, body, ctx, stage, assignee, workspace) do
    work_id = Id.new()
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "work",
             work_id: work_id,
             run_id: ctx.run_id,
             comment_id: comment_id,
             body: Jason.encode!(Map.put(body, "start", true))
           }),
         :ok <-
           Helpers.insert_work(conn, %{
             id: work_id,
             parent_id: nil,
             workspace: workspace,
             assignee: assignee,
             stage: stage,
             title: body["title"],
             goal: body["goal"],
             event_id: event.id,
             at: event.at
           }),
         :ok <-
           Helpers.insert_comment(conn, comment_id, %{works: work_id}, body["report"], event, ctx),
         :ok <- link_run(conn, ctx.run_id, work_id) do
      {:ok, event}
    end
  end

  defp link_run(_conn, nil, _work_id), do: :ok

  defp link_run(conn, run_id, work_id) do
    case Query.one(conn, "SELECT work_id FROM runs WHERE id = ?", [run_id]) do
      {:ok, %{work_id: nil}} ->
        Query.exec(conn, "UPDATE runs SET work_id = ? WHERE id = ?", [work_id, run_id])

      {:ok, _row} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
