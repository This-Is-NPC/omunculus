defmodule Omunculus.Runtime.Workflow do
  @moduledoc "Durable report/retry/break routing. Model comments carry all correction instructions."
  alias Omunculus.{EventCore, Runtime}
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Report

  def on_event(state, %{type: type})
      when type in [
             "run.completed",
             "run.failed",
             "task.retry_requested",
             "task.break",
             "task.commented",
             "task.completed"
           ],
      do: advance(state)

  def on_event(state, _), do: state

  def advance(state) do
    events = EventCore.stream(state.core, 0)

    state =
      Enum.reduce(events, state, fn env, acc ->
        case env do
          %{type: "run.completed", payload: %{"workflow" => true, "outcome" => "reported"}} ->
            if live?(acc, env.work_item_id) or handled?(acc.core, env),
              do: acc,
              else: handle_report(acc, env)

          %{type: "run.failed"} ->
            start = last_start(acc.core, env.work_item_id)

            if start && start.payload["workflow"] && not live?(acc, env.work_item_id) &&
                 not handled?(acc.core, env) do
              review = start.payload["review"]

              comment =
                "Technical failure; no valid model completion report. Inspect confirmed effects before continuing. " <>
                  (env.payload["reason"] || "unknown")

              if is_map(review) do
                old =
                  Enum.find(
                    EventCore.stream(acc.core, 0, type: "task.break"),
                    &(&1.event_id == review["break_id"])
                  )

                resolve_break(acc, old, comment)

                emit_break(
                  acc,
                  env,
                  review["target"],
                  parent(acc.core, env.work_item_id),
                  comment
                )
              else
                emit_break(
                  acc,
                  env,
                  env.work_item_id,
                  parent(acc.core, env.work_item_id),
                  comment
                )
              end

              emit(acc.core, env, "task.report_handled", env.work_item_id, %{
                report_id: env.event_id
              })
            end

            acc

          _ ->
            acc
        end
      end)

    state =
      EventCore.stream(state.core, 0, type: "task.retry_requested")
      |> Enum.reduce(state, fn request, acc ->
        target = request.work_item_id

        if activated?(acc, request) or live?(acc, target),
          do: acc,
          else:
            Runtime.start_workflow_run(
              acc,
              spec(acc.core, request, target, request.payload["checkpoint"], "retry")
            )
      end)

    EventCore.stream(state.core, 0, type: "task.break")
    |> Enum.reduce(state, &route_break(&2, &1))
  end

  defp handle_report(state, env) do
    report = env.payload["report"]
    review = env.payload["review"]

    state =
      cond do
        is_map(review) ->
          review_report(state, env, report, review)

        report["completed"] ->
          complete(state, env, env.work_item_id, report["comment"])

        child = env.payload["checkpoint"]["review_child"] ->
          emit(state.core, env, "task.reopened", child, %{comment: report["comment"]})

          if retry_count(state.core, child) >= max_retries(state.core, child) or
               report["break"] == true do
            emit_break(state, env, child, env.work_item_id, report["comment"])
            state
          else
            retry(state, env, child, report["comment"])
          end

        report["break"] == true or
            retry_count(state.core, env.work_item_id) >= env.payload["max_retries"] ->
          emit_break(
            state,
            env,
            env.work_item_id,
            parent(state.core, env.work_item_id),
            report["comment"]
          )

          state

        true ->
          retry(state, env, env.work_item_id, report["comment"])
      end

    emit(state.core, env, "task.report_handled", env.work_item_id, %{report_id: env.event_id})
    state
  end

  defp review_report(state, env, report, review) do
    target = review["target"]

    break_env =
      Enum.find(
        EventCore.stream(state.core, 0, type: "task.break"),
        &(&1.event_id == review["break_id"])
      )

    cond do
      live?(state, target) ->
        state

      report["completed"] ->
        resolve_break(state, break_env, report["comment"])
        complete(state, env, target, report["comment"])

      report["break"] == true ->
        resolve_break(state, break_env, report["comment"])
        emit_break(state, env, target, parent(state.core, env.work_item_id), report["comment"])
        state

      true ->
        resolve_break(state, break_env, report["comment"])
        retry(state, env, target, report["comment"])
    end
  end

  defp route_break(state, env) do
    cond do
      resolved?(state.core, env) ->
        state

      completed?(state.core, env.payload["target"]) ->
        completion =
          EventCore.stream(state.core, 0,
            work_item_id: env.payload["target"],
            type: "task.completed"
          )
          |> List.last()

        resolve_break(state, env, completion.payload["result"])
        state

      live?(state, env.payload["target"]) ->
        state

      env.payload["reviewer"] == nil ->
        human(state, env)

      true ->
        reviewer = env.payload["reviewer"]

        cond do
          live?(state, reviewer) ->
            state

          activated?(state, env) ->
            state

          review_count(state.core, reviewer, env.payload["target"]) >
              max_retries(state.core, reviewer) ->
            resolve_break(state, env, env.payload["comment"])

            emit_break(
              state,
              env,
              env.payload["target"],
              parent(state.core, reviewer),
              env.payload["comment"]
            )

            state

          true ->
            start_review(state, env, reviewer)
        end
    end
  end

  defp start_review(state, env, reviewer) do
    restore = checkpoint(state.core, reviewer)
    target = env.payload["target"]

    context = """
    BREAK: evaluate work item #{target} for your responsible role.
    Your original task: #{instruction(state.core, reviewer)}
    Target task: #{instruction(state.core, target)}
    Execution checkpoint (confirmed tool state): #{Jason.encode!(checkpoint(state.core, target)["tool_state"] || %{})}
    Recent Run comments: #{comments(state.core, target)}
    Previous model comment: #{env.payload["comment"]}
    Return completed and comment. true recognizes the target as completed; false
    authorizes another attempt using your comment. break=true escalates upward.
    """

    review = %{"break_id" => env.event_id, "target" => target, "restore" => restore}

    spec =
      spec(state.core, env, reviewer, %{}, "break")
      |> Map.put(:instruction, context)
      |> Map.put(:review, review)

    Runtime.start_workflow_run(state, spec)
  end

  defp human(state, env) do
    request =
      emit(
        state.core,
        env,
        "task.commented",
        env.payload["target"],
        %{
          kind: "request",
          request_id: env.event_id,
          body:
            "Break: #{instruction(state.core, env.payload["target"])}\n#{env.payload["comment"]}\nRecent Run comments: #{comments(state.core, env.payload["target"])}",
          break_id: env.event_id
        },
        :command
      )

    reply =
      EventCore.stream(state.core, 0, type: "task.commented")
      |> Enum.find(
        &(&1.payload["kind"] == "response" and
            (&1.payload["request_id"] == env.event_id or &1.causation_id == request.event_id))
      )

    if reply do
      emit(state.core, reply, "inbox.read", reply.work_item_id, %{id: request.event_id}, :command)

      case Report.parse(reply.payload["body"]) do
        {:ok, %{"completed" => true, "comment" => comment}} ->
          state = complete(state, reply, env.payload["target"], comment)
          resolve_break(state, env, comment)
          state

        _ ->
          comment =
            case Report.parse(reply.payload["body"]) do
              {:ok, r} -> r["comment"]
              _ -> reply.payload["body"]
            end

          state = retry(state, reply, env.payload["target"], comment)
          resolve_break(state, env, comment)
          state
      end
    else
      state
    end
  end

  defp retry(state, cause, target, comment) do
    cp = checkpoint(state.core, target)

    cp =
      Map.put(
        cp,
        "messages",
        (cp["messages"] || []) ++
          [%{"role" => "user", "content" => "Previous Run / responsible comment:\n" <> comment}]
      )

    emit(state.core, cause, "task.reopened", target, %{comment: comment})
    emit(state.core, cause, "task.retry_requested", target, %{comment: comment, checkpoint: cp})
    state
  end

  def completed?(core, target) do
    case EventCore.stream(core, 0, work_item_id: target, type: "task.completed") |> List.last() do
      nil -> false
      env -> current_completion?(core, env)
    end
  end

  def current_completion?(core, env) do
    not Enum.any?(
      EventCore.stream(core, 0, work_item_id: env.work_item_id, type: "task.reopened"),
      &(&1.sequence > env.sequence)
    )
  end

  defp complete(state, cause, target, comment) do
    unless completed?(state.core, target) do
      start = last_start(state.core, target)

      emit(state.core, cause, "task.completed", target, %{
        result: comment,
        depth: start.payload["depth"],
        completed: true,
        comment: comment
      })
    end

    state
  end

  defp spec(core, cause, target, checkpoint, reason) do
    start = last_start(core, target)
    p = start.payload

    %{
      activation: cause,
      work_item_id: target,
      correlation_id: cause.correlation_id,
      depth: p["depth"],
      attempt: length(EventCore.stream(core, 0, work_item_id: target, type: "run.started")) + 1,
      instruction: instruction(core, target),
      parent_run_id: p["parent_run_id"],
      originating_run_id: p["originating_run_id"],
      checkpoint: checkpoint,
      project_id: cause.project_id,
      session_id: start.session_id,
      workspace: p["workspace"],
      workspace_id: start.workspace_id,
      node_id: p["node_id"],
      team: p["team"],
      agent: p["agent_id"],
      reason: reason
    }
  end

  defp checkpoint(core, target) do
    events = EventCore.stream(core, 0, work_item_id: target)
    closed = Enum.filter(events, &(&1.type == "run.completed")) |> List.last()

    cp =
      cond do
        closed && is_map(closed.payload["review"]) -> closed.payload["review"]["restore"] || %{}
        closed -> closed.payload["checkpoint"] || %{}
        true -> %{}
      end

    tool =
      Enum.filter(
        events,
        &(&1.type == "tool.call.completed" and is_map(&1.payload["checkpoint"]))
      )
      |> List.last()

    if tool && (is_nil(closed) or tool.sequence > closed.sequence),
      do: Map.put(cp, "tool_state", tool.payload["checkpoint"]),
      else: cp
  end

  defp comments(core, target) do
    EventCore.query(
      core,
      "SELECT body FROM COMMENTS WHERE work_item_id = ? AND kind = 'run' ORDER BY last_sequence DESC LIMIT 8",
      [target]
    )
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp instruction(core, target) do
    initial =
      EventCore.stream(core, 0, work_item_id: target, type: "task.requested") |> List.first()

    initial =
      initial ||
        Enum.find(
          EventCore.stream(core, 0, type: "task.delegated"),
          &(&1.payload["child_work_item_id"] == target)
        )

    if initial, do: initial.payload["instruction"], else: ""
  end

  defp parent(core, target) do
    case EventCore.query(
           core,
           "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?",
           [target]
         ) do
      [[p]] when is_binary(p) -> p
      _ -> nil
    end
  end

  defp last_start(core, target),
    do: EventCore.stream(core, 0, work_item_id: target, type: "run.started") |> List.last()

  defp retry_count(core, target),
    do:
      EventCore.stream(core, 0, work_item_id: target, type: "run.started")
      |> Enum.count(&(&1.payload["reason"] == "retry"))

  defp review_count(core, reviewer, target),
    do:
      EventCore.stream(core, 0, work_item_id: reviewer, type: "run.started")
      |> Enum.count(&(get_in(&1.payload, ["review", "target"]) == target))

  defp max_retries(core, reviewer), do: last_start(core, reviewer).payload["max_retries"] || 2

  defp live?(state, target),
    do: Enum.any?(state.runs, fn {_, run} -> run.work_item_id == target end)

  defp activated?(state, env),
    do:
      Enum.any?(state.runs, fn {_, run} -> run.activation_id == env.event_id end) or
        Enum.any?(
          EventCore.stream(state.core, 0, type: "run.started"),
          &(&1.causation_id == env.event_id)
        )

  defp handled?(core, env),
    do:
      Enum.any?(
        EventCore.stream(core, 0, type: "task.report_handled"),
        &(&1.payload["report_id"] == env.event_id)
      )

  defp resolved?(core, env),
    do:
      Enum.any?(
        EventCore.stream(core, 0, type: "task.break.resolved"),
        &(&1.payload["break_id"] == env.event_id)
      )

  defp resolve_break(state, env, comment) do
    resolution =
      emit(state.core, env, "task.break.resolved", env.work_item_id, %{
        break_id: env.event_id,
        comment: comment
      })

    for request <- EventCore.stream(state.core, 0, type: "task.commented"),
        request.payload["kind"] == "request" and request.payload["break_id"] == env.event_id do
      emit(
        state.core,
        resolution,
        "inbox.read",
        env.work_item_id,
        %{id: request.event_id},
        :command
      )
    end

    resolution
  end

  defp emit_break(state, cause, target, reviewer, comment),
    do:
      emit(state.core, cause, "task.break", target, %{
        target: target,
        reviewer: reviewer,
        comment: comment
      })

  defp emit(core, cause, type, target, payload, kind \\ :event) do
    EventCore.append!(
      core,
      Envelope.new(kind, type,
        schema_version: if(type == "task.completed", do: "2", else: "1"),
        work_item_id: target,
        correlation_id: cause.correlation_id,
        session_id: cause.session_id,
        workspace_id: cause.workspace_id,
        project_id: cause.project_id,
        causation_id: cause.event_id,
        idempotency_key: "workflow:#{type}:#{cause.event_id}:#{target}",
        payload: payload
      )
    )
  end
end
