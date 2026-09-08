defmodule Omunculus.Runtime.Run do
  @moduledoc """
  One durable attempt (Run) of an Execution Node executing a Work Item
  (docs/to-be/execution-model.md).

  The process is an ephemeral Session: it is not the source of truth. Every
  transition goes through the Event Core and the process only continues after
  the corresponding envelope has been committed **and delivered back** to it,
  which is the flow drawn in the `conte até 10` scenarios of event-model.md:

      tool.call.requested -> append+commit -> deliver -> execute
      tool.call.completed -> append+commit -> deliver -> next round

  Delegation appends `task.delegated` and returns `{:wait, ...}` so the run
  can close with `run.completed` outcome `waiting`. A continuation run resumes
  from the checkpoint when children finish; `run.*` and `model.call.*` hang
  off the chain as side branches so the documented chain is preserved.
  """

  use GenServer, restart: :temporary

  alias Omunculus.{Agent, EventCore, FS, Permission, Tools}
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Permission, as: RuntimePermission
  alias Omunculus.Tool.Context

  @delivery_timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = Map.new(opts)
    :ok = EventCore.subscribe(state.core, correlation_id: state.correlation_id)
    {:ok, state, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state) do
    state =
      Map.put(state, :recovery, Omunculus.Runtime.Recovery.for_run(state, current_stage(state)))

    activation = state.activation
    Process.put(:chain_head, activation.event_id)
    Process.put(:awaiting_children, [])

    checkpoint = state.checkpoint || %{}
    reason = state[:reason] || state["reason"] || "initial"

    tools_bands = state[:tools] || bands_from_agent(state.agent)

    started =
      append!(
        state,
        :event,
        "run.started",
        %{
          recovery: state.recovery,
          work_item: state.work_item,
          comment: state[:comment],
          attempt: state.attempt,
          depth: state.depth,
          parent_run_id: state.parent_run_id,
          originating_run_id: state.originating_run_id,
          agent_id: state.agent.agent_id,
          agent_kind: state.agent.kind,
          model: state.agent[:model],
          max_turns: state.agent[:max_turns] || 32,
          reason: reason,
          checkpoint: checkpoint,
          flow: state.agent[:flow] || %{"steps" => [], "root_approval" => "self"},
          stage: current_stage(state),
          max_retries: state.agent[:max_retries] || 2,
          assessment: state[:assessment],
          tools: tools_bands,
          control_tools: control_tools(state),
          available_tools: available_tools(state),
          directory_scope: state[:directory_scope] || "subtree",
          discovery: Map.take(state.agent[:tool_options] || %{}, [:workspaces, :teams, :agents]),
          team: state[:team] || state["team"],
          node_id: state[:node_id],
          workspace: state[:workspace],
          session_id: state[:session_id] || state.activation.session_id
        }
        |> maybe_put_policy_hash(state[:policy_hash])
      )

    Process.put(:run_started_id, started.event_id)

    run_agent(state, checkpoint)
  end

  defp run_agent(state, checkpoint) do
    remaining = checkpoint_awaiting(checkpoint)
    remaining_pending = fetch_key(checkpoint, "pending") || %{}
    agent = state.agent
    active_tools = executable_tools(state)

    opts = [
      on_retry: &reserve_recovery(state, &1),
      report_required: not (state[:arbitration] || state[:cross_lineage_arbitration] || false),
      instruction: Omunculus.WorkItem.render(state.work_item, state[:comment]),
      chat: agent.chat,
      fs: state[:fs] || fs_for_roots(state[:roots]),
      tools: active_tools,
      max_turns: agent[:max_turns] || 32,
      instructions: agent[:instructions],
      system_prompt: agent[:system_prompt],
      tool_options: tool_options_for(agent, state),
      tool_state: tool_state_from(checkpoint),
      tool_executor: &execute_tool(state, &1, &2, &3, &4),
      tool_wrapper: &record_tool(state, &1, &2),
      reporter: &report(state, &1),
      request_permission: state[:request_permission] || agent[:request_permission]
    ]

    opts =
      case checkpoint_messages(checkpoint) do
        messages when is_list(messages) -> Keyword.put(opts, :messages, messages)
        _ -> opts
      end

    opts =
      cond do
        state[:cross_lineage_arbitration] ->
          Keyword.merge(opts,
            schemas: cross_lineage_arbitration_schemas(),
            tools: ["forward", "rewrite", "deny"],
            request_permission: false
          )

        state[:arbitration] ->
          Keyword.merge(opts,
            schemas: arbitration_schemas(),
            tools: ["grant", "deny", "escalate"],
            request_permission: false
          )

        true ->
          opts
      end

    opts =
      if !(state[:arbitration] || state[:cross_lineage_arbitration]),
        do: contextual_options(opts, agent),
        else: Keyword.put(opts, :report_required, false)

    outcome = Agent.run(opts)

    case outcome do
      {status, result} when status in [:ok, :waiting] ->
        Process.put(:last_model_comment, result.assistant_text)

      _ ->
        :ok
    end

    new_children = Process.get(:awaiting_children, [])

    case outcome do
      {:waiting, result} ->
        pending =
          Map.merge(remaining_pending, pending_from_messages(result.messages, new_children))

        finish_waiting(state, result, remaining ++ new_children, pending: pending)

      {:ok, result} when remaining != [] ->
        finish_waiting(state, result, remaining,
          pending: remaining_pending,
          notes: result.assistant_text
        )

      {:ok, result} ->
        if !(state[:arbitration] || state[:cross_lineage_arbitration]),
          do: finish_report(state, result),
          else: finish_arbitration(state, result)

      {:error, reason} ->
        append!(state, :event, "run.failed", %{reason: inspect(reason)})
        {:stop, :normal, state}
    end
  end

  defp current_stage(state) do
    steps = (state.agent[:flow] || %{})["steps"] || []

    if state.attempt == 1 and steps != [],
      do: hd(steps)["name"],
      else: Omunculus.Runtime.Workflow.stage(state.core, state.work_item_id)
  end

  defp nonempty_comment(text) when is_binary(text) do
    if String.trim(text) == "",
      do: "No model comment was produced; completion is unverified.",
      else: text
  end

  defp nonempty_comment(_), do: "No model comment was produced; completion is unverified."

  defp contextual_options(opts, agent) do
    # Refresh only the system layer, retaining all conversation and tool-call links.
    messages = Keyword.get(opts, :messages)

    opts =
      if is_list(messages) and messages != [] do
        Keyword.put(opts, :messages, [
          %{
            "role" => "system",
            "content" => agent[:system_prompt] || Omunculus.Runtime.Report.instruction()
          }
          | Enum.reject(messages, &(&1["role"] == "system"))
        ])
      else
        opts
      end

    schemas =
      Keyword.get(opts, :schemas) ||
        Agent.schemas_for(Keyword.fetch!(opts, :tools), Keyword.get(opts, :request_permission))

    # Permission schema is assembled by Agent; leave that path intact.
    schemas =
      Enum.map(schemas, fn schema ->
        if get_in(schema, ["function", "name"]) in [
             "delegate",
             "request_work",
             "request_permission"
           ] do
          update_in(schema, ["function", "parameters"], fn p ->
            p
            |> Map.update!(
              "properties",
              &Map.put(&1, "comment", %{
                "type" => "string",
                "description" => "Run summary and handoff context"
              })
            )
            |> Map.update("required", ["comment"], &Enum.uniq(&1 ++ ["comment"]))
          end)
        else
          schema
        end
      end)

    Keyword.put(opts, :schemas, schemas)
  end

  defp finish_report(state, result) do
    report =
      case Omunculus.Runtime.Report.parse(result.assistant_text) do
        {:ok, report} when not is_map_key(result, :limit_reached) ->
          report

        _ ->
          %{
            "completed" => false,
            "comment" => nonempty_comment(result.assistant_text || Process.get(:handoff_comment)),
            "break" => true
          }
      end

    prior = state.checkpoint || %{}

    checkpoint = %{
      "messages" => result.messages,
      "tool_state" => result.tool_state,
      "awaiting" => prior["awaiting"] || [],
      "pending" => prior["pending"] || %{}
    }

    append!(state, :event, "run.completed", %{
      outcome: "reported",
      report: report,
      comment: report["comment"],
      checkpoint: checkpoint,
      assessment:
        if(state[:assessment],
          do: put_in(state.assessment, ["restore", "tool_state"], result.tool_state)
        ),
      max_retries: state.agent[:max_retries] || 2,
      rounds: result.turns,
      tool_calls: result.tool_calls,
      report_valid: match?({:ok, _}, Omunculus.Runtime.Report.parse(result.assistant_text))
    })

    {:stop, :normal, state}
  end

  defp finish_waiting(state, result, awaiting, opts) do
    pending = Keyword.fetch!(opts, :pending)

    checkpoint =
      %{
        "messages" => result.messages,
        "tool_state" => result.tool_state,
        "awaiting" => awaiting,
        "pending" => pending
      }
      |> Map.put("assessment", state[:assessment])
      |> maybe_put_notes(Keyword.get(opts, :notes))

    append!(
      state,
      :event,
      "run.completed",
      %{
        outcome: "waiting",
        awaiting: awaiting,
        checkpoint: checkpoint,
        assessment: state[:assessment],
        comment: nonempty_comment(Process.get(:handoff_comment) || result.assistant_text)
      },
      Process.get(:chain_head)
    )

    {:stop, :normal, state}
  end

  defp finish_arbitration(state, result) do
    if state[:cross_lineage_arbitration] do
      payload =
        cond do
          reason = Process.get(:cross_lineage_denied) ->
            %{cross_lineage_denied: reason}

          Process.get(:cross_lineage_forwarded) ->
            %{cross_lineage_forwarded: true}

          true ->
            %{cross_lineage_denied: "mediator returned without a decision"}
        end
        |> Map.merge(%{
          outcome: "waiting",
          awaiting: (state[:arbitration_restore] || %{})[:awaiting] || [],
          checkpoint: (state[:arbitration_restore] || %{})[:checkpoint] || %{},
          request_event_id: state.cross_lineage_request.event_id,
          rounds: result.turns,
          tool_calls: result.tool_calls,
          usage: result.usage
        })

      append!(state, :event, "run.completed", payload, Process.get(:chain_head))
      {:stop, :normal, state}
    else
      if state[:arbitration] do
        restore = state[:arbitration_restore] || %{awaiting: [], checkpoint: %{}}

        append!(
          state,
          :event,
          "run.completed",
          %{
            outcome: "waiting",
            awaiting: restore[:awaiting] || restore["awaiting"] || [],
            checkpoint: restore[:checkpoint] || restore["checkpoint"] || %{},
            rounds: result.turns,
            tool_calls: result.tool_calls,
            usage: result.usage
          },
          Process.get(:chain_head)
        )

        {:stop, :normal, state}
      end
    end
  end

  @impl true
  def handle_info({:event_core, _env}, state), do: {:noreply, state}

  # --- tool execution through the core -------------------------------------------

  defp execute_tool(state, "delegate", args, context, active) do
    Process.put(:handoff_comment, args["comment"])

    with true <- "delegate" in active,
         {:ok, _item} <- Omunculus.WorkItem.handoff(args),
         :ok <- reserve_delegation(state) do
      delegate(state, args, context)
    else
      false -> {:error, :denied, context}
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp execute_tool(state, "request_work", args, context, active) do
    Process.put(:handoff_comment, args["comment"])

    with true <- "request_work" in active,
         {:ok, _item} <- Omunculus.WorkItem.handoff(args),
         :ok <- reserve_delegation(state) do
      request_work(state, args, context)
    else
      false -> {:error, :denied, context}
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp execute_tool(state, "request_permission", args, context, _active) do
    Process.put(:handoff_comment, args["comment"])
    request_permission(state, args, context)
  end

  defp execute_tool(state, tool, args, context, _active)
       when tool in ["grant", "deny", "escalate"] do
    cond do
      state[:arbitration] ->
        arbitration_tool(state, tool, args, context)

      state[:cross_lineage_arbitration] and tool == "deny" ->
        cross_lineage_tool(state, tool, args, context)

      true ->
        {:error, :denied, context}
    end
  end

  defp execute_tool(state, tool, args, context, _active)
       when tool in ["forward", "rewrite", "deny"] do
    if state[:cross_lineage_arbitration],
      do: cross_lineage_tool(state, tool, args, context),
      else: {:error, :denied, context}
  end

  defp execute_tool(state, name, args, context, active) do
    authorized_tool_call(state, name, args, context, active)
  end

  defp control_tools(state) do
    cond do
      state[:cross_lineage_arbitration] -> ["forward", "rewrite", "deny"]
      state[:arbitration] -> ["grant", "deny", "escalate"]
      state[:request_permission] || state.agent[:request_permission] -> ["request_permission"]
      true -> []
    end
  end

  defp record_tool(state, call, execute) do
    started_at = System.monotonic_time(:millisecond)

    requested =
      append!(state, :event, "tool.call.requested", %{
        tool: call.tool,
        args: call.args,
        round: call.round,
        tool_call_id: call.tool_call_id,
        counter: counter_payload(call.tool, call.context)
      })

    result =
      case await_delivery_or_rejection(requested.event_id) do
        :ok ->
          if Process.get(:recovery_exhausted),
            do: {:error, :max_retries_exhausted, call.context},
            else: execute.()

        {:rejected, rejection} ->
          {:error, {:delivery_rejected, rejection.payload["reason"]}, call.context}
      end

    {outcome, body, context} =
      case result do
        {:ok, output, ctx} -> {"completed", output, ctx}
        {:wait, output, ctx} -> {"waiting", output, ctx}
        {:error, reason, ctx} -> {"error", Agent.format_tool_error(reason), ctx}
      end

    completed =
      append!(
        state,
        :event,
        "tool.call.completed",
        %{
          tool: call.tool,
          round: call.round,
          tool_call_id: call.tool_call_id,
          outcome: outcome,
          output: body,
          duration_ms: System.monotonic_time(:millisecond) - started_at,
          previous:
            if(outcome == "completed",
              do: counter_value(call.tool, Context.tool_state(context, call.tool, nil), :previous)
            ),
          new:
            if(outcome == "completed",
              do: counter_value(call.tool, Context.tool_state(context, call.tool, nil), :new)
            ),
          checkpoint: checkpoint(context)
        },
        requested.event_id
      )

    await_delivery(completed.event_id)
    Process.put(:chain_head, completed.event_id)
    result
  end

  defp authorized_tool_call(state, name, args, context, active) do
    {:ok, allowed?} =
      EventCore.transaction(state.core, fn conn ->
        Permission.tool_allowed?(
          conn,
          state.work_item_id,
          name,
          (state[:tools] || bands_from_agent(state.agent))["granted"] || []
        )
      end)

    if allowed?,
      do: Tools.call_context(name, args, context, active),
      else: {:error, :denied, context}
  end

  # Depth policy is not the node's business: a configured DepthGate
  # interceptor may reject the delivery of task.delegated, in which case the
  # child never starts and the rejection comes back to the model as a tool
  # error, with delivery.rejected as the new head of the causation chain.
  defp delegated_recovery(state) do
    if state[:assessment] || state[:reason] == "continuation" ||
         state.recovery["work_item_id"] != state.work_item_id,
       do: state.recovery
  end

  defp reserve_delegation(state) do
    if delegated_recovery(state), do: reserve_recovery(state, "delegation"), else: :ok
  end

  defp reserve_recovery(state, reason) do
    cause_id =
      if reason == "report_format",
        do: Process.get(:model_result_id),
        else: Process.get(:chain_head)

    cause = %{state.activation | event_id: cause_id, run_id: state.run_id}

    case Omunculus.Runtime.Recovery.reserve(state.core, state.recovery, cause, reason) do
      {:ok, _} ->
        :ok

      {:error, :max_retries_exhausted} = error ->
        Process.put(:recovery_exhausted, true)
        error
    end
  end

  defp delegate(state, args, context) do
    child = Envelope.generate_id("wi")
    work_item = args["work_item"]

    payload =
      %{
        recovery: delegated_recovery(state),
        work_item: work_item,
        comment: args["comment"] || args[:comment],
        child_work_item_id: child,
        to_depth: state.depth + 1,
        parent_run_id: state.run_id,
        originating_run_id: state.originating_run_id || state.run_id,
        tools: tools_pin(state),
        team: args["team"] || args[:team] || state[:team],
        agent: args["agent"] || args[:agent]
      }
      |> maybe_put_workspace(args)

    delegated =
      append!(
        state,
        :event,
        "task.delegated",
        payload,
        nil,
        workspace_id: delegated_workspace_id(args)
      )

    case await_delivery_or_rejection(delegated.event_id) do
      :ok ->
        children = Process.get(:awaiting_children, [])
        Process.put(:awaiting_children, children ++ [child])
        {:wait, "delegated", context}

      {:rejected, rejection} ->
        Process.put(:chain_head, rejection.event_id)
        {:error, {:delegation_rejected, rejection.payload["reason"]}, context}
    end
  end

  defp request_work(state, args, context) do
    child = Envelope.generate_id("wi")
    work_item = args["work_item"]

    payload =
      %{
        recovery: delegated_recovery(state),
        work_item: work_item,
        comment: args["comment"] || args[:comment],
        requested_by: "run:" <> state.run_id,
        child_work_item_id: child,
        requester_work_item_id: state.work_item_id,
        workspace: args["workspace"] || args[:workspace] || state[:workspace],
        team: args["team"] || args[:team] || state[:team] || "default",
        agent: args["agent"] || args[:agent]
      }
      |> drop_nil_fields()

    requested =
      append!(
        state,
        :event,
        "task.requested",
        payload,
        nil,
        idempotency_key: "request_work:" <> child
      )

    case await_delivery_or_rejection(requested.event_id) do
      :ok ->
        children = Process.get(:awaiting_children, [])
        Process.put(:awaiting_children, children ++ [child])
        {:wait, "request_work", context}

      {:rejected, rejection} ->
        Process.put(:chain_head, rejection.event_id)
        {:error, {:request_work_rejected, rejection.payload["reason"]}, context}
    end
  end

  # A delegation is either delivered back to us or rejected by the lane; the
  # rejection carries causation to the envelope we appended.
  defp await_delivery_or_rejection(event_id) do
    receive do
      {:event_core, %Envelope{event_id: ^event_id}} ->
        :ok

      {:event_core, %Envelope{type: "delivery.rejected", causation_id: ^event_id} = env} ->
        {:rejected, env}
    after
      @delivery_timeout -> raise "event #{event_id} was committed but never delivered"
    end
  end

  defp await_delivery(event_id) do
    receive do
      {:event_core, %Envelope{event_id: ^event_id}} -> :ok
    after
      @delivery_timeout -> raise "event #{event_id} was committed but never delivered"
    end
  end

  defp request_permission(state, args, context) do
    tool = permission_tool_name(args)
    reason = args["reason"] || args[:reason] || ""
    bands = state[:tools] || bands_from_agent(state.agent)
    policy_granted = bands["granted"] || []
    continuation? = state[:reason] in ["continuation", "retry"]
    parent_bands = RuntimePermission.parent_bands_from_log(state.core, state.work_item_id)

    {:ok, decision} =
      EventCore.transaction(state.core, fn conn ->
        request_id = Permission.request_id(conn, state.work_item_id, tool)

        cond do
          Permission.already_granted?(conn, state.work_item_id, tool, policy_granted) and
              continuation? ->
            {:already, tool}

          Permission.already_granted?(conn, state.work_item_id, tool, policy_granted) ->
            {:wait_policy}

          true ->
            case Permission.denied_reason(conn, state.work_item_id, tool) do
              {:ok, denial_reason} ->
                {:denied, denial_reason}

              :error ->
                arbiter = RuntimePermission.arbiter(tool, bands, parent_bands, state.depth)
                {:request, request_id, arbiter}
            end
        end
      end)

    case decision do
      {:already, granted_tool} ->
        {:ok, "already granted: " <> granted_tool, context}

      {:wait_policy} ->
        existing = Process.get(:awaiting_children, [])
        Process.put(:awaiting_children, existing ++ ["policy"])
        {:wait, "policy", context}

      {:denied, denial_reason} ->
        {:error, "denied for this task: " <> denial_reason, context}

      {:request, request_id, arbiter} ->
        workspace = state[:workspace] || state[:workspace_id]

        payload =
          %{
            request_id: request_id,
            tool: tool,
            reason: reason,
            arbiter: format_arbiter(arbiter)
          }
          |> maybe_put_permission_workspace(workspace)

        append!(
          state,
          :event,
          "permission.requested",
          payload,
          Process.get(:chain_head),
          idempotency_key: request_id
        )

        existing = Process.get(:awaiting_children, [])
        Process.put(:awaiting_children, existing ++ [request_id])
        {:wait, request_id, context}
    end
  end

  defp arbitration_tool(state, "grant", args, context) do
    reason = args["reason"] || args[:reason] || ""
    request_id = state[:arbitration_request_id]
    child_wi = state[:arbitration_child_wi] || state.work_item_id

    append!(
      state,
      :command,
      "permission.granted",
      %{
        request_id: request_id,
        kind: "temporary",
        granter: "run:" <> state.run_id,
        reason: reason
      },
      Process.get(:chain_head),
      work_item_id: child_wi
    )

    {:ok, "granted", context}
  end

  defp arbitration_tool(state, "deny", args, context) do
    reason = args["reason"] || args[:reason] || "denied"
    request_id = state[:arbitration_request_id]
    child_wi = state[:arbitration_child_wi] || state.work_item_id

    append!(
      state,
      :command,
      "permission.denied",
      %{request_id: request_id, reason: reason},
      Process.get(:chain_head),
      work_item_id: child_wi
    )

    {:ok, "denied", context}
  end

  defp arbitration_tool(state, "escalate", args, context) do
    reason = args["reason"] || args[:reason] || "escalated"
    child_wi = state[:arbitration_child_wi] || state.work_item_id

    append!(
      state,
      :command,
      "task.commented",
      %{kind: "request", body: reason},
      Process.get(:chain_head),
      work_item_id: child_wi
    )

    {:ok, "escalated", context}
  end

  defp cross_lineage_tool(state, "forward", _args, context) do
    work_item = state[:cross_lineage_work_item]
    cross_lineage_delegate(state, work_item, context)
  end

  defp cross_lineage_tool(state, "rewrite", args, context) do
    Process.put(:handoff_comment, args["comment"])

    with {:ok, work_item} <- Omunculus.WorkItem.handoff(args) do
      cross_lineage_delegate(state, work_item, context)
    else
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp cross_lineage_tool(_state, "deny", args, context) do
    reason = args["reason"] || args[:reason] || "denied"
    Process.put(:cross_lineage_denied, reason)
    {:ok, "denied", context}
  end

  defp cross_lineage_delegate(state, work_item, context) do
    req = state[:cross_lineage_request]
    payload = req.payload

    delegated =
      append!(
        state,
        :event,
        "task.delegated",
        %{
          recovery: payload["recovery"],
          work_item: work_item,
          comment: Process.get(:handoff_comment) || payload["comment"],
          child_work_item_id: payload["child_work_item_id"],
          to_depth: state.cross_lineage_target_depth,
          parent_run_id: state.run_id,
          originating_run_id: state.originating_run_id || state.run_id,
          team: payload["team"],
          agent: payload["agent"],
          workspace: payload["workspace"],
          requested_by: payload["requested_by"],
          requester_work_item_id: payload["requester_work_item_id"] || req.work_item_id
        },
        Process.get(:chain_head),
        workspace_id: payload["workspace"]
      )

    await_delivery(delegated.event_id)
    Process.put(:cross_lineage_forwarded, true)
    {:ok, "forwarded", context}
  end

  defp permission_tool_name(args) do
    args["tool"] || args[:tool] || args["name"] || args[:name] ||
      raise(ArgumentError, "request_permission requires tool")
  end

  defp format_arbiter(:forbidden), do: "forbidden"
  defp format_arbiter(arbiter) when is_binary(arbiter), do: arbiter

  defp maybe_put_permission_workspace(payload, nil), do: payload

  defp maybe_put_permission_workspace(payload, workspace),
    do: Map.put(payload, :workspace, workspace)

  defp cross_lineage_arbitration_schemas do
    [
      cross_lineage_schema(
        "forward",
        "Forward the cross-lineage request unchanged.",
        []
      ),
      cross_lineage_schema(
        "rewrite",
        "Forward a revised Work Item with the decision in comment.",
        ["work_item", "comment"]
      ),
      cross_lineage_schema("deny", "Deny the cross-lineage request.", ["reason"])
    ]
  end

  defp cross_lineage_schema(name, description, required) do
    properties = %{
      "reason" => %{"type" => "string", "description" => "Why this decision was made."},
      "work_item" => Omunculus.WorkItem.schema(),
      "comment" => %{"type" => "string", "minLength" => 1}
    }

    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => required
        }
      }
    }
  end

  defp arbitration_schemas do
    [
      arbitration_schema("grant", "Grant a permission request.", ["reason"]),
      arbitration_schema("deny", "Deny a permission request.", ["reason"]),
      arbitration_schema("escalate", "Escalate a permission request to a human.", ["reason"])
    ]
  end

  defp arbitration_schema(name, description, required) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "reason" => %{"type" => "string", "description" => "Why this decision was made."}
          },
          "required" => required
        }
      }
    }
  end

  # --- side branches --------------------------------------------------------------

  defp report(state, %{type: :round_started} = ev) do
    event =
      append!(state, :event, "model.call.requested", %{
        round: ev.round,
        model: state.agent[:model],
        messages: ev.messages,
        schemas: ev.schemas
      })

    Process.put(:model_request_id, event.event_id)
    :ok
  end

  defp report(state, %{type: :round_completed} = ev) do
    event =
      append!(
        state,
        :event,
        "model.call.completed",
        %{
          call_id: Process.get(:model_request_id),
          round: ev.round,
          outcome: ev.outcome,
          usage: ev.usage,
          duration_ms: ev.duration_ms,
          model: state.agent[:model],
          response: ev.response
        },
        Process.get(:model_request_id)
      )

    Process.put(:model_result_id, event.event_id)
    :ok
  end

  defp report(state, %{type: :round_failed} = ev) do
    append!(
      state,
      :event,
      "model.call.failed",
      %{
        call_id: Process.get(:model_request_id),
        round: ev.round,
        reason: inspect(ev.reason),
        duration_ms: ev.duration_ms,
        model: state.agent[:model]
      },
      Process.get(:model_request_id)
    )

    :ok
  end

  defp report(_state, _ev), do: :ok

  # --- helpers ---------------------------------------------------------------------

  defp append!(state, kind, type, payload, causation_id \\ nil, opts \\ []) do
    workspace_id =
      Keyword.get(opts, :workspace_id) ||
        delegated_child_workspace_id(type, payload) ||
        state[:workspace_id] ||
        state.activation.workspace_id

    payload =
      if type == "run.completed",
        do: Map.put_new(payload, :comment, nonempty_comment(Process.get(:last_model_comment))),
        else: payload

    env =
      Envelope.new(kind, type,
        schema_version: "1",
        correlation_id: state.correlation_id,
        causation_id: causation_id || Process.get(:chain_head),
        idempotency_key: Keyword.get(opts, :idempotency_key),
        session_id: state[:session_id] || state.activation.session_id,
        workspace_id: workspace_id,
        project_id: state[:project_id],
        work_item_id: Keyword.get(opts, :work_item_id) || state.work_item_id,
        run_id: state.run_id,
        payload: payload
      )

    EventCore.append!(state.core, env)
  end

  defp checkpoint(%Context{state: tool_state}) when map_size(tool_state) == 0, do: nil
  defp checkpoint(%Context{state: tool_state}), do: tool_state

  defp counter_payload("counter", context) do
    options = Context.tool_options(context, "counter")
    %{increment: options[:increment] || options["increment"] || 1}
  end

  defp counter_payload(_name, _context), do: nil

  defp counter_value("counter", %{value: value, increment: inc}, :previous), do: value - inc
  defp counter_value("counter", %{value: value}, :new), do: value
  defp counter_value(_name, _state, _which), do: nil

  defp maybe_put_notes(checkpoint, nil), do: checkpoint
  defp maybe_put_notes(checkpoint, notes), do: Map.put(checkpoint, "notes", notes)

  defp pending_from_messages(messages, child_ids) do
    tool_call_ids =
      messages
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
          Enum.map(calls, fn call -> call["id"] || call[:id] end)

        _ ->
          nil
      end)

    child_ids
    |> Enum.zip(tool_call_ids)
    |> Map.new()
  end

  defp checkpoint_awaiting(checkpoint) do
    fetch_key(checkpoint, "awaiting") || []
  end

  defp checkpoint_messages(checkpoint) do
    case fetch_key(checkpoint, "messages") do
      messages when is_list(messages) -> messages
      _ -> nil
    end
  end

  defp tool_state_from(checkpoint) when is_map(checkpoint) do
    base = fetch_key(checkpoint, "tool_state") || %{}

    atomize_tool_state(base)
  end

  defp tool_state_from(_), do: %{}

  defp fetch_key(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_key(_, _), do: nil

  defp atomize_tool_state(map) when is_map(map) do
    Map.new(map, fn {tool, state} when is_map(state) ->
      {to_string(tool),
       Map.new(state, fn
         {k, v} when is_binary(k) -> {String.to_atom(k), v}
         {k, v} when is_atom(k) -> {k, v}
       end)}
    end)
  end

  defp bands_from_agent(agent) do
    %{
      "granted" => agent.tools,
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp available_tools(state) do
    cond do
      state[:cross_lineage_arbitration] ->
        ["forward", "rewrite", "deny"]

      state[:arbitration] ->
        ["grant", "deny", "escalate"]

      true ->
        executable_tools(state) ++
          if((state[:request_permission] || state.agent[:request_permission]) == true,
            do: ["request_permission"],
            else: []
          )
    end
  end

  defp executable_tools(state), do: state.agent.tools

  defp tools_pin(state) do
    state[:tools] || bands_from_agent(state.agent)
  end

  defp maybe_put_policy_hash(payload, nil), do: payload
  defp maybe_put_policy_hash(payload, hash), do: Map.put(payload, :policy_hash, hash)

  defp maybe_put_workspace(payload, args) do
    case args["workspace"] || args[:workspace] do
      nil -> payload
      workspace -> Map.put(payload, :workspace, workspace)
    end
  end

  defp delegated_child_workspace_id("task.delegated", payload),
    do: payload["workspace"] || payload[:workspace]

  defp delegated_child_workspace_id(_, _), do: nil
  defp delegated_workspace_id(args), do: args["workspace"] || args[:workspace]

  defp fs_for_roots(nil), do: FS.Memory.new(%{})
  defp fs_for_roots([]), do: FS.Memory.new(%{})

  defp fs_for_roots([root | _]) do
    alias Omunculus.FS.Disk
    Disk.new(Path.expand(root))
  end

  defp drop_nil_fields(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp tool_options_for(agent, state) do
    base = agent[:tool_options] || %{}

    base =
      case state[:roots] do
        roots when is_list(roots) and roots != [] -> Map.put(base, :roots, roots)
        _ -> base
      end

    base
    |> maybe_put_tool_option(:directory_scope, state[:directory_scope])
    |> maybe_put_tool_option(:team, state[:team] || state["team"])
    |> maybe_put_tool_option(:core, state.core)
  end

  defp maybe_put_tool_option(opts, _key, nil), do: opts
  defp maybe_put_tool_option(opts, key, value), do: Map.put(opts, key, value)
end
