defmodule Omunculus.Runtime.Workflow do
  @moduledoc "Durable report/retry/break routing. Model comments carry all correction instructions."
  alias Omunculus.{EventCore, Runtime}
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.{Report, Recovery}

  def on_event(state, %{type: type})
      when type in [
             "run.completed",
             "run.failed",
             "task.run_requested",
             "task.break",
             "task.assessment_requested",
             "task.advanced",
             "task.commented",
             "task.completed"
           ],
      do: advance(state)

  def on_event(state, _), do: state

  def advance(state) do
    events = Runtime.events(state)

    state =
      Enum.reduce(events, state, fn env, acc ->
        case env do
          %{type: "run.completed", payload: %{"outcome" => "reported"}} ->
            if live?(acc, env.work_item_id) or handled?(acc.core, env),
              do: acc,
              else: handle_report(acc, env)

          %{type: "run.failed"} ->
            start = Enum.find(events, &(&1.type == "run.started" and &1.run_id == env.run_id))

            if start && not live?(acc, env.work_item_id) &&
                 not handled?(acc.core, env) do
              review = start.payload["assessment"]

              comment =
                env.payload["comment"] ||
                  "Technical failure; no valid model completion report. Inspect confirmed effects before continuing. " <>
                    (env.payload["reason"] || "unknown")

              if is_map(review) do
                old =
                  Enum.find(
                    requests(acc),
                    &(&1.event_id == review["request_id"])
                  )

                emit_break(
                  acc,
                  env,
                  review["target"],
                  parent(acc.core, env.work_item_id),
                  comment
                )

                resolve_break(acc, old, comment)
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

    for advanced <- Runtime.events(state, type: "task.advanced") do
      checkpoint =
        case Omunculus.Interception.changed_comment(state.core, advanced) do
          nil ->
            advanced.payload["checkpoint"]

          comment ->
            Omunculus.Interception.context_checkpoint(
              advanced.payload["checkpoint"],
              Omunculus.WorkItem.load(state.core, advanced.work_item_id),
              comment
            )
        end

      emit(state.core, advanced, "task.run_requested", advanced.work_item_id, %{
        comment: advanced.payload["comment"],
        checkpoint: checkpoint,
        reason: "step",
        stage: advanced.payload["to"]
      })
    end

    state =
      Runtime.events(state, type: "task.run_requested")
      |> Enum.reduce(state, fn request, acc ->
        target = request.work_item_id

        if activated?(acc, request) or live?(acc, target) or completed?(acc.core, target) or
             request.payload["stage"] != stage(acc.core, target),
           do: acc,
           else:
             Runtime.start_workflow_run(
               acc,
               spec(
                 acc.core,
                 request,
                 target,
                 request.payload["checkpoint"],
                 request.payload["reason"]
               )
             )
      end)

    # An actor's processing failure returns to its owning interaction before
    # generic root-break routing can ask a human prematurely.
    state = Omunculus.Interception.Agents.advance(state)

    requests(state)
    |> Enum.reduce(state, &route_break(&2, &1))
  end

  defp handle_report(state, env) do
    report = env.payload["report"]
    review = env.payload["assessment"]

    state =
      cond do
        Enum.any?(
          Runtime.events(state),
          &(&1.causation_id == env.event_id and
                &1.type in [
                  "task.run_requested",
                  "task.advanced",
                  "task.completed",
                  "task.break",
                  "task.assessment_requested"
                ])
        ) ->
          if is_map(review) do
            request = Enum.find(requests(state), &(&1.event_id == review["request_id"]))
            resolve_break(state, request, report["comment"])
          end

          state

        is_map(review) ->
          assessment_report(state, env, report, review)

        parent(state.core, env.work_item_id) != nil ->
          reviewer = parent(state.core, env.work_item_id)

          if report["break"] == true do
            emit_break(state, env, env.work_item_id, reviewer, report["comment"])
          else
            request_assessment(state, env, env.work_item_id, reviewer, report["comment"])
          end

          state

        report["completed"] and flow(state.core, env.work_item_id)["root_approval"] == "human" ->
          request_assessment(state, env, env.work_item_id, nil, report["comment"])
          state

        report["completed"] ->
          approve(state, env, env.work_item_id, report["comment"])

        report["break"] == true or
            recovery_exhausted?(state.core, env.work_item_id) ->
          emit_break(state, env, env.work_item_id, nil, report["comment"])
          state

        true ->
          retry(state, env, env.work_item_id, report["comment"])
      end

    emit(state.core, env, "task.report_handled", env.work_item_id, %{report_id: env.event_id})
    state
  end

  defp assessment_report(state, env, report, review) do
    target = review["target"]

    break_env =
      Enum.find(
        requests(state),
        &(&1.event_id == review["request_id"])
      )

    cond do
      resolved?(state.core, break_env) or stale?(state.core, break_env) or live?(state, target) ->
        state

      report["completed"] ->
        state = approve(state, env, target, report["comment"])
        resolve_break(state, break_env, report["comment"])
        state

      report["break"] == true ->
        emit_break(state, env, target, parent(state.core, env.work_item_id), report["comment"])
        resolve_break(state, break_env, report["comment"])
        state

      break_env.type == "task.assessment_requested" and
          recovery_exhausted?(state.core, target) ->
        emit_break(state, env, target, env.work_item_id, report["comment"])
        resolve_break(state, break_env, report["comment"])
        state

      true ->
        state = retry(state, env, target, report["comment"])
        resolve_break(state, break_env, report["comment"])
        state
    end
  end

  defp route_break(state, env) do
    cond do
      resolved?(state.core, env) ->
        state

      completed?(state.core, env.payload["target"]) ->
        completion =
          Runtime.events(state,
            work_item_id: env.payload["target"],
            type: "task.completed"
          )
          |> List.last()

        resolve_break(state, env, completion.payload["result"])
        state

      stale?(state.core, env) ->
        resolve_break(state, env, "The reviewed stage already advanced.")
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

          true ->
            start_assessment(state, env, reviewer)
        end
    end
  end

  defp start_assessment(state, env, reviewer) do
    restore = checkpoint(state.core, reviewer)
    target = env.payload["target"]

    context = """
    Parent assessment: evaluate work item #{target} for your responsible role.
    Your original task: #{instruction(state.core, reviewer)}
    Target task: #{instruction(state.core, target)}
    Target stage: #{env.payload["stage"]}
    Stage instructions: #{stage_instructions(state.core, target)}
    Execution checkpoint (confirmed tool state): #{Jason.encode!(checkpoint(state.core, target)["tool_state"] || %{})}
    Recent Run comments: #{comments(state.core, target)}
    Previous model comment: #{env.payload["comment"]}
    Return completed and comment. true approves the current target stage; false
    authorizes another attempt using your comment. break=true escalates upward.
    """

    review = %{
      "request_id" => env.event_id,
      "target" => target,
      "stage" => env.payload["stage"],
      "restore" => restore,
      "comment" => env.payload["comment"]
    }

    spec =
      spec(
        state.core,
        env,
        reviewer,
        %{"tool_state" => restore["tool_state"] || %{}},
        if(env.type == "task.break", do: "break", else: "assessment")
      )
      |> Map.put(:comment, context)
      |> Map.put(:assessment, review)

    Runtime.start_workflow_run(state, spec)
  end

  defp human(state, env) do
    request =
      Enum.find(
        Runtime.events(state, type: "task.commented"),
        &(&1.causation_id == env.event_id and &1.payload["kind"] == "request")
      ) ||
        emit(
          state.core,
          env,
          "task.commented",
          env.payload["target"],
          %{
            kind: "request",
            request_id: env.event_id,
            body:
              "Review: #{instruction(state.core, env.payload["target"])}\n#{env.payload["comment"]}\nRecent Run comments: #{comments(state.core, env.payload["target"])}",
            assessment: true
          },
          :command
        )

    reply =
      Runtime.events(state, type: "task.commented")
      |> Enum.find(
        &(&1.payload["kind"] == "response" and
            (&1.payload["request_id"] == env.event_id or &1.causation_id == request.event_id))
      )

    if reply do
      emit(state.core, reply, "inbox.read", reply.work_item_id, %{id: request.event_id}, :command)

      case Report.parse(reply.payload["body"]) do
        {:ok, %{"completed" => true, "comment" => comment}} ->
          state = approve(state, reply, env.payload["target"], comment)
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
    case Recovery.reserve(state.core, Recovery.reference(state.core, target), cause, "retry") do
      {:ok, _} ->
        schedule_retry(state, cause, target, comment)

      {:error, :max_retries_exhausted} ->
        reviewer =
          if cause.payload["assessment"],
            do: parent(state.core, cause.work_item_id),
            else: parent(state.core, target)

        emit_break(state, cause, target, reviewer, comment)
        state
    end
  end

  defp schedule_retry(state, cause, target, comment) do
    cp = checkpoint(state.core, target)

    cp =
      Map.put(
        cp,
        "messages",
        (cp["messages"] || []) ++
          [%{"role" => "user", "content" => "Previous Run / responsible comment:\n" <> comment}]
      )

    emit(state.core, cause, "task.run_requested", target, %{
      comment: comment,
      checkpoint: cp,
      reason: "retry",
      stage: retry_stage(state.core, target)
    })

    state
  end

  defp retry_stage(core, target) do
    if (flow(core, target) || %{})["steps"] in [nil, []],
      do: "in_progress",
      else: stage(core, target)
  end

  def completed?(core, target) do
    case EventCore.delivered_stream(core, 0, work_item_id: target, type: "task.completed")
         |> List.last() do
      nil -> false
      _env -> true
    end
  end

  def flow(core, target) do
    case EventCore.delivered_stream(core, 0, work_item_id: target, type: "run.started")
         |> List.first() do
      nil -> nil
      env -> env.payload["flow"]
    end
  end

  def stage(core, target) do
    case EventCore.query(core, "SELECT status FROM WORK_ITEMS WHERE work_item_id = ?", [target]) do
      [[status]] -> status
      _ -> "to_do"
    end
  end

  defp stage_instructions(core, target) do
    Enum.find_value((flow(core, target) || %{})["steps"] || [], "", fn step ->
      if step["name"] == stage(core, target), do: step["instructions"]
    end)
  end

  defp approve(state, cause, target, comment) do
    steps = (flow(state.core, target) || %{})["steps"] || []
    current = stage(state.core, target)
    index = Enum.find_index(steps, &(&1["name"] == current))
    next = if index != nil, do: Enum.at(steps, index + 1)

    if next do
      cp = %{
        "tool_state" => checkpoint(state.core, target)["tool_state"] || %{},
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "Original task (reference criteria): #{instruction(state.core, target)}\nCurrent stage: #{next["name"]}. #{next["instructions"]}\nConfirmed tool state: #{Jason.encode!(checkpoint(state.core, target)["tool_state"] || %{})}\nPrevious responsible comment: #{comment}"
          }
        ],
        "awaiting" => [],
        "pending" => %{}
      }

      emit(state.core, cause, "task.advanced", target, %{
        from: current,
        to: next["name"],
        comment: comment,
        checkpoint: cp
      })

      state
    else
      complete(state, cause, target, comment)
    end
  end

  defp requests(state),
    do:
      Runtime.events(state)
      |> Enum.filter(&(&1.type in ["task.break", "task.assessment_requested"]))

  defp stale?(core, request) do
    stage(core, request.payload["target"]) != request.payload["stage"] or
      last_start(core, request.payload["target"]).run_id != request.payload["target_run_id"]
  end

  defp request_assessment(state, cause, target, reviewer, comment) do
    emit(state.core, cause, "task.assessment_requested", target, %{
      target: target,
      reviewer: reviewer,
      comment: comment,
      stage: stage(state.core, target),
      target_run_id: last_start(state.core, target).run_id
    })
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
      attempt:
        length(EventCore.delivered_stream(core, 0, work_item_id: target, type: "run.started")) + 1,
      work_item: Omunculus.WorkItem.load(core, target),
      comment: cause.payload["comment"],
      parent_run_id: p["parent_run_id"],
      originating_run_id: p["originating_run_id"],
      checkpoint: checkpoint,
      project_id: cause.project_id,
      session_id: start.session_id,
      workspace: p["workspace"],
      workspace_id: start.workspace_id,
      node_id: p["node_id"],
      team: p["team"],
      agent:
        (EventCore.delivered_stream(core, 0, work_item_id: target, type: "run.started")
         |> List.first()).payload["agent_id"],
      reason: reason
    }
  end

  def checkpoint(core, target) do
    events = EventCore.delivered_stream(core, 0, work_item_id: target)
    closed = Enum.filter(events, &(&1.type == "run.completed")) |> List.last()

    cp =
      cond do
        closed && closed.payload["outcome"] == "reported" && is_map(closed.payload["assessment"]) ->
          closed.payload["assessment"]["restore"] || %{}

        closed ->
          closed.payload["checkpoint"] || %{}

        true ->
          %{}
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
    EventCore.delivered_stream(core, 0, work_item_id: target)
    |> Enum.flat_map(fn env ->
      case env do
        %{type: "run.completed", payload: p} ->
          comment = get_in(p, ["report", "comment"]) || p["comment"]
          if is_binary(comment) and comment != "", do: [comment], else: []

        %{type: "task.commented", payload: %{"kind" => "run", "body" => body}} ->
          [body]

        _ ->
          []
      end
    end)
    |> Enum.take(-8)
    |> Enum.join("\n")
  end

  defp instruction(core, target), do: Omunculus.WorkItem.load(core, target)["instruction"]

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
    do:
      EventCore.delivered_stream(core, 0, work_item_id: target, type: "run.started")
      |> List.last()

  defp recovery_exhausted?(core, target) do
    ref = Recovery.reference(core, target)
    Recovery.used(core, ref) >= ref["max_retries"]
  end

  defp live?(state, target),
    do: Enum.any?(state.runs, fn {_, run} -> run.work_item_id == target end)

  defp activated?(state, env),
    do:
      Enum.any?(state.runs, fn {_, run} -> run.activation_id == env.event_id end) or
        Enum.any?(
          Runtime.events(state, type: "run.started"),
          &(&1.causation_id == env.event_id)
        )

  defp handled?(core, env),
    do:
      Enum.any?(
        EventCore.delivered_stream(core, 0, type: "task.report_handled"),
        &(&1.payload["report_id"] == env.event_id)
      )

  defp resolved?(core, env),
    do:
      Enum.any?(
        EventCore.delivered_stream(core, 0, type: "task.assessment_resolved"),
        &(&1.payload["request_id"] == env.event_id)
      )

  defp resolve_break(state, env, comment) do
    resolution =
      emit(state.core, env, "task.assessment_resolved", env.work_item_id, %{
        request_id: env.event_id,
        comment: comment
      })

    for request <- Runtime.events(state, type: "task.commented"),
        request.payload["kind"] == "request" and request.payload["request_id"] == env.event_id do
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
        stage: stage(state.core, target),
        target_run_id: last_start(state.core, target).run_id,
        comment: comment
      })

  defp emit(core, cause, type, target, payload, kind \\ :event) do
    EventCore.append!(
      core,
      Envelope.new(kind, type,
        schema_version: "1",
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
