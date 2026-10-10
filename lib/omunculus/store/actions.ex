defmodule Omunculus.Store.Actions do
  @moduledoc """
  Write side of the store: `run/3` applies the emits from a tool's
  `out.emit` in order, inside whatever transaction the caller holds — the
  whole batch commits or nothing does (spec §8.3). `work` creates a root
  work with the `report` as its first comment and links the run to it when
  the run has no work yet. Of its `works`, one naming an agent of depth 0
  — or unnamed, when depth 0 has a workflow or depth 1 no agent — is the
  root itself, marked to start; when each names an agent of depth 1 or
  none, the root is held by the run's agent and each is delegated below
  it, so the root's run opens once they are back. `work` and
  `delegate` may name the new work's `agent`: one of the TOML's agents at
  its depth that is not `workflow_only`, refused when that depth has a
  workflow; unnamed, it is the first stage's agent or the depth's first
  agent.
  `continue`, `break`, `delegate`, `cancel` and `end` are
  dispatched to `Actions.Sequence`; `request`, `reply` and `grant` to
  `Actions.Requests`; `notify` and `inbox.read` to `Actions.Inbox`;
  `compact` and `comment.delete` to `Actions.Comments`.
  """

  alias Omunculus.{Config, Id}
  alias Omunculus.Store.Actions.{Comments, Contract, Helpers, Inbox, Requests, Sequence}
  alias Omunculus.Store.{Events, Query}

  @comment_targets %{"work_id" => :works, "request_id" => :requests, "inbox_id" => :inbox}

  @spec run(Omunculus.Store.Connection.t(), [map], map) :: {:ok, [map]} | {:error, term}
  def run(conn, emits, ctx) do
    Events.with_actor(conn, ctx, fn ->
      emits
      |> Enum.reduce_while({:ok, []}, fn emit, {:ok, events} ->
        case with(:ok <- Contract.validate(emit), do: dispatch(conn, emit, ctx)) do
          {:ok, result} -> {:cont, {:ok, [result | events]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, events} ->
          {:ok, events |> Enum.reverse() |> List.flatten() |> Enum.reject(&is_nil/1)}

        error ->
          error
      end
    end)
  end

  defp dispatch(conn, %{"type" => "comment"} = emit, ctx),
    do: comment(conn, Map.get(emit, "body", %{}), ctx)

  defp dispatch(conn, %{"type" => "prompt"} = emit, ctx),
    do: prompt(conn, Map.get(emit, "body", %{}), ctx)

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

  defp dispatch(conn, %{"type" => "continue"}, ctx), do: Sequence.continue(conn, ctx)

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

    with :ok <- Helpers.ensure_text(:comment, body, "body"),
         :ok <- ensure_target(targets),
         :ok <- Helpers.tag_error(:comment, Helpers.ensure_exist(conn, Map.to_list(targets))) do
      write_comment(conn, body, targets, ctx)
    end
  end

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

  defp prompt(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:prompt, body, "message"),
         :ok <-
           Helpers.tag_error(:prompt, Helpers.ensure_exist(conn, [{:works, body["work_id"]}])),
         {:ok, reopened} <- reopen_waiting_work(conn, body["work_id"]),
         {:ok, prompt_event} <- write_prompt(conn, body, ctx) do
      {:ok, Enum.reject([reopened, prompt_event], &is_nil/1)}
    end
  end

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

  defp write_prompt(conn, body, ctx) do
    prompt_id = Id.new()

    conversation_id =
      case body["work_id"] do
        nil ->
          Map.get(ctx, :conversation_id)

        work_id ->
          case Query.one(conn, "SELECT conversation_id FROM works WHERE id = ?", [work_id]) do
            {:ok, work} -> work && work.conversation_id
            _ -> nil
          end
      end

    with :ok <-
           Query.insert(conn, :prompts, %{
             id: prompt_id,
             conversation_id: conversation_id,
             actor_issuer: Map.get(ctx, :issuer),
             actor_subject: Map.get(ctx, :subject),
             kind: "message",
             body: body["message"],
             run_id: nil,
             created_at: Events.now()
           }) do
      Events.append(conn, %{
        type: "prompt",
        prompt_id: prompt_id,
        work_id: body["work_id"],
        conversation_id: conversation_id,
        actor_issuer: Map.get(ctx, :issuer),
        actor_subject: Map.get(ctx, :subject),
        body: Jason.encode!(body)
      })
    end
  end

  defp work(conn, body, ctx) do
    with :ok <- Helpers.ensure_text(:work, body, "report"),
         {:ok, items} <- work_items(body["works"]) do
      cond do
        down?(ctx.config, items) ->
          hand_down(conn, body["report"], items, ctx)

        match?([_], items) ->
          own_root(conn, body["report"], hd(items), ctx)

        true ->
          {:error, {:work, :one_root}}
      end
    end
  end

  # Works go to depth 1 when each names one of its agents or names none:
  # an unnamed work goes to the depth's first stage or first agent. Only a
  # work naming an agent of depth 0, or an unnamed one when depth 0 has a
  # workflow (its first stage takes the root) or depth 1 has no agent, is
  # the root itself.
  defp down?(config, items) do
    children = for {name, %{depth: 1}} <- config.agents, do: name

    unnamed_down? =
      Config.workflow_for(config, 0) == :off and
        (Config.agents_at_depth(config, 1) != [] or Config.workflow_for(config, 1) != :off)

    Enum.all?(items, &((is_nil(&1["agent"]) and unnamed_down?) or &1["agent"] in children))
  end

  defp work_items([_ | _] = items) do
    if Enum.all?(items, &item?/1),
      do: {:ok, items},
      else: {:error, {:work, {:invalid, "works"}}}
  end

  defp work_items(_items), do: {:error, {:work, {:invalid, "works"}}}

  defp item?(item) when is_map(item) do
    Enum.all?(item, fn {key, value} ->
      key in ~w(title goal agent workspace) and is_binary(value)
    end) and Enum.all?(~w(title goal), &(Map.get(item, &1, "") != ""))
  end

  defp item?(_item), do: false

  # One work for an agent of depth 0, or the depth's own, starts as the root.
  defp own_root(conn, report, item, ctx) do
    with {:ok, {stage, assignee}} <-
           Helpers.tag_error(:work, Helpers.stage_and_assignee(ctx.config, 0, item["agent"])),
         {:ok, workspace} <-
           Helpers.tag_error(:work, Helpers.resolve_workspace(ctx.config, item["workspace"], nil)) do
      create_root(conn, Map.put(item, "report", report), ctx, stage, assignee, workspace, true)
    end
  end

  # Works for agents of depth 1 go below a root the run's agent holds, which
  # does not start: its run opens once they are back.
  defp hand_down(conn, report, items, ctx) do
    held_by = if Config.workflow_for(ctx.config, 0) == :off, do: Map.get(ctx, :agent)

    root = %{
      "title" => Enum.map_join(items, "; ", & &1["title"]),
      "goal" => Enum.map_join(items, "\n\n", & &1["goal"]),
      "report" => report
    }

    with {:ok, {stage, assignee}} <-
           Helpers.tag_error(:work, Helpers.stage_and_assignee(ctx.config, 0, held_by)),
         {:ok, workspace} <-
           Helpers.tag_error(:work, Helpers.resolve_workspace(ctx.config, nil, nil)),
         {:ok, event} <- create_root(conn, root, ctx, stage, assignee, workspace, false) do
      items
      |> Enum.reduce_while({:ok, [event]}, fn item, {:ok, events} ->
        case Sequence.delegate(conn, item, Map.put(ctx, :work_id, event.work_id)) do
          {:ok, delegated} -> {:cont, {:ok, events ++ [delegated]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  # A root marked to start runs once the run that created it has ended.
  defp create_root(conn, body, ctx, stage, assignee, workspace, start) do
    work_id = Id.new()
    comment_id = Id.new()

    with {:ok, event} <-
           Events.append(conn, %{
             type: "work",
             work_id: work_id,
             run_id: ctx.run_id,
             comment_id: comment_id,
             body: Jason.encode!(Map.put(body, "start", start))
           }),
         :ok <-
           Helpers.insert_work(conn, %{
             id: work_id,
             conversation_id: event.conversation_id,
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
