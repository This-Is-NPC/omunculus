defmodule Omunculus.Runtime do
  @moduledoc """
  Consumer that turns accepted envelopes into Execution Nodes/Runs.

  * `task.requested` (command) starts a root Run at depth 0.
  * `task.delegated` (event) starts a child Run at `to_depth` with
    `parent_run_id`/`originating_run_id` taken from the event, so the reporting
    tree is derived from runtime links, never from Agent configuration.
  * `task.resumed` (command) derives attempt, depth, parent and checkpoint from
    the log and starts a **new** Run; the failed Run is never reopened.

  A crashed Run process is observed via monitor and recorded as `run.failed`.
  Delivery is at-least-once, so activation is deduplicated by `event_id`.
  """

  use GenServer

  alias Omunculus.EventCore
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Run
  alias Omunculus.Runtime.Permission, as: RuntimePermission
  alias Omunculus.{Config, Permission, Policy}

  # --- API ------------------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Submit a task as a command and wait for the root `task.completed`.
  Returns `{:ok, %{result:, requested:, completed:}}`.
  """
  def request(core, instruction, opts \\ []) do
    work_item_id = opts[:work_item_id] || Envelope.generate_id("wi")
    correlation_id = opts[:correlation_id] || Envelope.generate_id("corr")
    timeout = opts[:timeout] || 30_000

    payload =
      %{instruction: instruction, depth: 0, execution: opts[:execution] || %{}}
      |> maybe_put_workspace_payload(opts[:workspace])

    :ok = EventCore.subscribe(core, correlation_id: correlation_id)

    try do
      {:ok, requested} =
        EventCore.append(
          core,
          Envelope.command("task.requested",
            correlation_id: correlation_id,
            idempotency_key: opts[:idempotency_key],
            session_id: opts[:session_id],
            workspace_id: opts[:workspace_id],
            project_id: opts[:project_id],
            work_item_id: work_item_id,
            payload: payload
          )
        )

      # An idempotent re-submission returns the original command; its work item
      # is the one to wait for (or may already be complete in the log).
      wait_root(core, requested, timeout, opts[:return_on_human] == true)
    after
      EventCore.unsubscribe(core)
    end
  end

  @doc "Ask the runtime to start a new attempt for a failed work item."
  def resume(core, work_item_id, opts \\ []) do
    EventCore.append(
      core,
      Envelope.command("task.resumed",
        correlation_id: Keyword.fetch!(opts, :correlation_id),
        causation_id: opts[:causation_id],
        work_item_id: work_item_id,
        payload: %{reason: opts[:reason] || "operator"}
      )
    )
  end

  def runs(runtime), do: GenServer.call(runtime, :runs)

  # --- callbacks ------------------------------------------------------------------

  @impl true
  def init(opts) do
    core = Keyword.fetch!(opts, :core)
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    session_id = Keyword.get(opts, :session_id)
    :ok = EventCore.subscribe(core, if(session_id, do: [session_id: session_id], else: []))

    state =
      %{
        core: core,
        session_id: session_id,
        sup: sup,
        agents: Keyword.fetch!(opts, :agents),
        max_depth: Keyword.get(opts, :max_depth, 1),
        run_opts: Keyword.get(opts, :run_opts, []),
        config: normalize_runtime_config(Keyword.get(opts, :config)),
        runs: %{},
        pids: %{},
        handled: MapSet.new(),
        pending_continuations: %{},
        nodes: %{}
      }

    Omunculus.EventCore.Projector.sync_core(core)
    state = if Keyword.get(opts, :recover, false), do: recover_unfinished(state), else: state
    state = recover_cross_requests(state)
    state = rebuild_pending_continuations(state)
    state = flush_pending_continuations(state)

    state = Omunculus.Interception.Agents.advance(state)
    {:ok, Omunculus.Runtime.Workflow.advance(state)}
  end

  @doc false
  def events(state, opts \\ []) do
    opts = if state[:session_id], do: Keyword.put(opts, :session_id, state.session_id), else: opts
    EventCore.delivered_stream(state.core, 0, opts)
  end

  @impl true
  def handle_call(:runs, _from, state), do: {:reply, state.runs, state}

  @impl true
  def handle_info({:event_core, env}, state) do
    Omunculus.EventCore.Projector.sync_core(state.core)

    state =
      if env.type in ["interception.requested", "run.completed", "run.failed"],
        do: Omunculus.Interception.Agents.advance(state),
        else: state

    case EventCore.delivery(state.core, env) do
      :pending ->
        {:noreply, state}

      {:ready, effective} ->
        if MapSet.member?(state.handled, env.event_id) or activated?(state.core, effective) do
          {:noreply, state}
        else
          state = %{state | handled: MapSet.put(state.handled, env.event_id)}
          state = activate(effective, state) |> Omunculus.Runtime.Workflow.on_event(effective)

          state =
            if effective.type == "run.completed",
              do: state |> rebuild_pending_continuations() |> flush_pending_continuations(),
              else: state

          {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {run_id, pids} ->
        {run, runs} = Map.pop(state.runs, run_id)
        if reason != :normal, do: record_crash(state.core, run, reason)

        state = %{state | pids: pids, runs: runs}
        Omunculus.EventCore.Projector.sync_core(state.core)

        state =
          state
          |> Omunculus.Runtime.Workflow.advance()
          |> recover_cross_requests()
          |> rebuild_pending_continuations()
          |> flush_pending_continuations()

        {:noreply,
         maybe_continue_parent(state, run.work_item_id) |> Omunculus.Runtime.Workflow.advance()}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.sup), do: Supervisor.stop(state.sup)
    :ok
  end

  # --- activation -----------------------------------------------------------------

  defp activate(%Envelope{kind: :command, type: "task.requested"} = env, state) do
    start_run(state, %{
      activation: env,
      work_item_id: env.work_item_id,
      correlation_id: env.correlation_id,
      depth: 0,
      attempt: 1,
      work_item: Omunculus.WorkItem.from_activation(env),
      comment: env.payload["comment"],
      parent_run_id: nil,
      originating_run_id: nil,
      checkpoint: %{},
      project_id: env.project_id,
      session_id: env.session_id,
      workspace_id: nil,
      workspace: env.payload["workspace"]
    })
  end

  defp activate(%Envelope{kind: :event, type: "task.delegated"} = env, state) do
    p = env.payload
    depth = p["to_depth"]
    workspace = p["workspace"] || env.workspace_id

    start_run(state, %{
      activation: env,
      work_item_id: p["child_work_item_id"],
      correlation_id: env.correlation_id,
      depth: depth,
      attempt: 1,
      work_item: p["work_item"],
      comment: p["comment"],
      parent_run_id: p["parent_run_id"],
      originating_run_id: p["originating_run_id"],
      checkpoint: %{},
      project_id: env.project_id,
      session_id: env.session_id,
      workspace: workspace,
      workspace_id: if(depth > 0, do: workspace, else: nil),
      team: p["team"],
      agent: p["agent"]
    })
  end

  defp activate(
         %Envelope{kind: :event, type: "task.requested", payload: %{"requested_by" => _}} = env,
         state
       ) do
    route_request_work(state, env)
  end

  defp activate(%Envelope{kind: :command, type: "task.resumed"} = env, state) do
    case derive_resume(state.core, env.work_item_id) do
      {:ok, spec} ->
        start_run(state, Map.merge(spec, %{activation: env, correlation_id: env.correlation_id}))

      {:error, reason} ->
        EventCore.append!(
          state.core,
          Envelope.event("task.resume_rejected",
            correlation_id: env.correlation_id,
            causation_id: env.event_id,
            work_item_id: env.work_item_id,
            payload: %{reason: inspect(reason)}
          )
        )

        state
    end
  end

  defp activate(%Envelope{type: "task.completed"} = env, state) do
    case find_parent_waiter(state.core, env.work_item_id) do
      {:ok, parent_wi, run_completed} ->
        checkpoint = run_completed.payload["checkpoint"] || %{}
        awaiting = checkpoint["awaiting"] || []
        child_id = to_string(env.work_item_id)

        if child_id in Enum.map(awaiting, &to_string/1) and
             Omunculus.Runtime.Workflow.completed?(state.core, env.work_item_id) do
          maybe_continue_parent(state, parent_wi, env, run_completed, child_id, awaiting)
        else
          state
        end

      :error ->
        state
    end
  end

  defp activate(%Envelope{type: "workspace.attached"} = env, state) do
    register_attached_nodes(state, env)
  end

  defp activate(%Envelope{type: "workspace.detached"} = env, state) do
    fail_runs_in_workspace(state, env.payload["workspace_id"], env.session_id)
  end

  defp activate(%Envelope{type: "run.started"} = env, state) do
    case state.runs[env.run_id] do
      nil ->
        state

      run ->
        %{state | runs: Map.put(state.runs, env.run_id, %{run | started_event_id: env.event_id})}
    end
  end

  defp activate(%Envelope{type: "permission.requested"} = env, state) do
    arbiter = env.payload["arbiter"]

    state =
      if arbiter == "forbidden" do
        EventCore.append!(
          state.core,
          Envelope.command("permission.denied",
            session_id: env.session_id,
            correlation_id: env.correlation_id,
            causation_id: env.event_id,
            work_item_id: env.work_item_id,
            payload: %{
              request_id: env.payload["request_id"],
              reason: "forbidden"
            }
          )
        )

        state
      else
        state
      end

    if arbiter == "parent" do
      start_arbitration_run(state, env)
    else
      state
    end
  end

  defp activate(%Envelope{type: type} = env, state)
       when type in ["permission.granted", "permission.denied"] do
    request_id = env.payload["request_id"]

    RuntimePermission.waiting_for_request(state.core, request_id)
    |> Enum.reduce(state, fn {work_item_id, _}, st ->
      if live_run_for_work_item?(st, work_item_id, env.run_id) do
        st
      else
        reopen_permission_wait(st, env, work_item_id, request_id)
      end
    end)
  end

  defp activate(
         %Envelope{type: "run.completed", payload: %{"cross_lineage_denied" => reason}} = env,
         state
       ) do
    maybe_reopen_cross_lineage_denial(state, env, reason)
  end

  defp activate(%Envelope{type: "run.completed", payload: %{"outcome" => "waiting"}} = env, state) do
    awaiting = env.payload["awaiting"] || []

    if "policy" in Enum.map(awaiting, &to_string/1) do
      reopen_policy_wait(state, env, env.run_id)
    else
      state
    end
  end

  defp activate(%Envelope{type: "policy.changed"} = env, state) do
    grant_open_requests_by_policy(state, env)
  end

  defp activate(_env, state), do: state

  @doc false
  def start_workflow_run(state, spec), do: start_run(state, spec)

  defp start_run(%{session_id: id} = state, %{session_id: other})
       when not is_nil(id) and id != other,
       do: state

  defp start_run(state, spec) do
    original_config = state.config
    execution = task_execution(state.core, spec)

    effective =
      Map.merge(
        original_config || %{},
        Map.take(execution, [:cwd, :config_file, :profile, :tools])
      )

    state = %{state | config: if(effective == %{}, do: nil, else: effective)}

    result =
      case resolve_policy(state, spec) do
        {:error, reason} ->
          policy_invalid(state, spec, reason)

        {:ok, agent, bands, policy_hash, request_permission, spec, state} ->
          spec = initial_comment(spec, agent)

          spec =
            case Omunculus.Interception.changed_comment(state.core, spec.activation) do
              nil ->
                spec

              comment ->
                comment = spec[:comment] || comment

                spec
                |> Map.put(:comment, comment)
                |> Map.put(
                  :checkpoint,
                  Omunculus.Interception.context_checkpoint(
                    spec.checkpoint,
                    spec.work_item,
                    comment
                  )
                )
            end

          start_run_with_agent(state, spec, agent, bands, policy_hash, request_permission)
      end

    %{result | config: original_config}
  end

  defp task_execution(core, spec) do
    root = root_work_item_id(core, spec.work_item_id)
    activation = find_activation(core, root) || spec.activation
    payload = activation.payload["execution"] || %{}

    for key <- [:cwd, :config_file, :profile, :tools, :provider, :model, :base_url, :max_turns],
        value = payload[Atom.to_string(key)] || payload[key],
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp activated?(core, env) do
    env.type in ["task.requested", "task.delegated", "task.resumed"] and
      EventCore.query(
        core,
        "SELECT 1 FROM EVENTS WHERE type = 'run.started' AND causation_id = ? LIMIT 1",
        [env.event_id]
      ) != []
  end

  defp recover_unfinished(state) do
    events = events(state)
    starts = Enum.filter(events, &(&1.type == "run.started"))
    # A closed Run can be awaiting interception; it is not a crashed process.
    closed =
      EventCore.stream(state.core, 0)
      |> Enum.filter(&(&1.type in ["run.completed", "run.failed"]))

    for start <- starts,
        not Enum.any?(
          closed,
          &(&1.run_id == start.run_id)
        ) do
      EventCore.append!(
        state.core,
        Envelope.event("run.failed",
          session_id: start.session_id,
          workspace_id: start.workspace_id,
          work_item_id: start.work_item_id,
          run_id: start.run_id,
          correlation_id: start.correlation_id,
          causation_id: start.event_id,
          payload: %{reason: "runtime_restarted", crashed: true}
        )
      )

      EventCore.append!(
        state.core,
        Envelope.command("task.commented",
          session_id: start.session_id,
          workspace_id: start.workspace_id,
          work_item_id: start.work_item_id,
          correlation_id: start.correlation_id,
          causation_id: start.event_id,
          payload: %{
            kind: "request",
            body: "Interrupted run: inspect effects before retrying with task.resumed."
          }
        )
      )
    end

    Enum.reduce(events, state, fn env, acc ->
      wi =
        if env.type == "task.delegated",
          do: env.payload["child_work_item_id"],
          else: env.work_item_id

      initial? =
        (env.type == "task.requested" and env.kind == :command) or env.type == "task.delegated"

      rejected? =
        Enum.any?(events, &(&1.type == "delivery.rejected" and &1.causation_id == env.event_id))

      if not rejected? and
           ((initial? and not Enum.any?(starts, &(&1.work_item_id == wi))) or
              (env.type == "task.resumed" and not activated?(state.core, env))) do
        EventCore.redeliver(acc.core, env.event_id)
        acc
      else
        acc
      end
    end)
  end

  defp start_run_with_agent(state, spec, agent, bands, policy_hash, request_permission) do
    spec = Map.put_new(spec, :comment, spec.activation.payload["comment"])
    run_id = Envelope.generate_id("run")

    opts =
      spec
      |> Map.merge(%{
        core: state.core,
        run_id: run_id,
        agent: agent,
        tools: bands,
        policy_hash: policy_hash,
        request_permission: request_permission,
        max_depth: state.max_depth,
        reason: Map.get(spec, :reason, "initial"),
        directory_scope: Map.get(agent, :directory_scope)
      })
      |> Map.merge(Map.new(state.run_opts))
      |> Map.to_list()

    {:ok, pid} = DynamicSupervisor.start_child(state.sup, {Run, opts})
    ref = Process.monitor(pid)

    run = %{
      pid: pid,
      ref: ref,
      run_id: run_id,
      session_id: spec.session_id,
      work_item_id: spec.work_item_id,
      correlation_id: spec.correlation_id,
      activation_id: spec.activation.event_id,
      started_event_id: nil,
      depth: spec.depth,
      attempt: spec.attempt,
      workspace_id: Map.get(spec, :workspace_id) || Map.get(spec, :workspace)
    }

    %{state | runs: Map.put(state.runs, run_id, run), pids: Map.put(state.pids, pid, run_id)}
  end

  defp resolve_policy(state, spec) do
    case state.config do
      nil -> resolve_policy_without_config(state, spec)
      config -> resolve_policy_with_config(state, spec, config)
    end
  end

  defp resolve_policy_without_config(state, spec) do
    workspace = Map.get(spec, :workspace) || spec.activation.payload["workspace"]

    roots =
      case attached_workspace_row(state.core, workspace, spec.session_id) do
        {:ok, attached_roots, _} -> attached_roots
        :error -> Map.get(spec, :roots, [])
      end

    spec = Map.put(spec, :roots, roots)
    {spec, state} = assign_node_id(state, spec, nil)
    agent = state.agents.(agent_context(state, spec))

    agent =
      merge_config_tool_options(agent, %{workspaces: %{}, teams: %{}, agents: %{}}, spec, state)

    bands = bands_from_tools(agent.tools)
    bands = if agent[:tool_policy], do: Policy.intersect(bands, agent.tool_policy), else: bands
    agent = %{agent | tools: bands["granted"]}
    {:ok, agent, bands, nil, false, spec, state}
  end

  defp resolve_policy_with_config(state, spec, config) do
    load_opts = [
      cwd: config[:cwd] || File.cwd!(),
      config_file: config[:config_file],
      env: config[:env] || %{}
    ]

    with {:ok, loaded} <- Config.load(load_opts),
         {:ok, _checked} <- Config.check(loaded),
         table when is_map(table) <- Policy.table(loaded),
         hash <- Policy.hash(table),
         :ok <- maybe_emit_policy_loaded(state, spec, hash, table),
         profile = resolve_profile(spec, loaded, config),
         workspace = resolve_workspace(spec, loaded, state),
         depth = to_string(spec.depth),
         {:ok, line_bands} <- Policy.line(table, profile, depth, workspace),
         {:ok, ceiling} <- policy_ceiling(loaded, depth, workspace),
         true <- Policy.fits_ceiling?(line_bands, ceiling),
         {:ok, narrow_bands} <- maybe_intersect_team_profile(loaded, spec, line_bands),
         {:ok, bands} <- maybe_narrow_tools(config, narrow_bands) do
      roots = workspace_roots(state, workspace, loaded, spec.session_id)

      spec =
        spec
        |> Map.put(:workspace, workspace)
        |> Map.put(:workspace_id, envelope_workspace_id(spec, workspace))
        |> Map.put(:roots, roots)
        |> Map.put(:session_id, spec.session_id || spec.activation.session_id)

      {spec, state} = assign_node_id(state, spec, loaded)

      {:ok, lineage_tools} =
        EventCore.transaction(state.core, fn conn ->
          Permission.active_lineage_tools(conn, spec.work_item_id)
        end)

      granted_tools = Enum.uniq((bands["granted"] || []) ++ lineage_tools)
      agent = state.agents.(agent_context(state, spec, loaded))
      bands = Map.put(bands, "granted", granted_tools)
      bands = if agent[:tool_policy], do: Policy.intersect(bands, agent.tool_policy), else: bands
      agent = %{agent | tools: bands["granted"]}
      agent = merge_config_tool_options(agent, loaded, spec, state)

      request_permission =
        negotiable_or_human?(bands) or Map.get(spec, :request_permission, false)

      {:ok, agent, bands, hash, request_permission, spec, state}
    else
      false -> {:error, :profile_outside_ceiling}
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_ceiling(loaded, depth, workspace) do
    catalog_version = loaded.session[:tools_catalog]

    depth_policy = Map.get(loaded.policy, depth, %{})
    workspace_entry = Map.get(loaded.workspaces, workspace, %{})
    workspace_policy = Map.get(workspace_entry, :policy, %{})

    with {:ok, depth_bands} <- Policy.normalize(depth_policy, catalog_version: catalog_version),
         {:ok, workspace_bands} <-
           Policy.normalize(workspace_policy, catalog_version: catalog_version) do
      {:ok, Policy.intersect(depth_bands, workspace_bands)}
    end
  end

  defp maybe_emit_policy_loaded(state, spec, hash, table) do
    last =
      state.core
      |> EventCore.delivered_stream(0, type: "policy.loaded", session_id: spec.session_id)
      |> List.last()

    if last && last.payload["hash"] == hash do
      :ok
    else
      EventCore.append!(
        state.core,
        Envelope.event("policy.loaded",
          session_id: spec.session_id,
          correlation_id: spec.correlation_id,
          causation_id: spec.activation.event_id,
          payload: %{hash: hash, table: encode_policy_table(table)}
        )
      )

      :ok
    end
  end

  defp policy_invalid(state, spec, reason) do
    EventCore.append!(
      state.core,
      Envelope.event("run.failed",
        session_id: spec.session_id,
        correlation_id: spec.correlation_id,
        causation_id: spec.activation.event_id,
        work_item_id: spec.work_item_id,
        payload: %{reason: "policy_invalid", detail: inspect(reason)}
      )
    )

    state
  end

  defp encode_policy_table(table) do
    table
    |> Enum.map(fn {{profile, depth, workspace}, bands} ->
      %{
        "profile" => profile,
        "depth" => depth,
        "workspace" => workspace,
        "granted" => bands["granted"],
        "negotiable" => bands["negotiable"],
        "human" => bands["human"],
        "forbidden" => bands["forbidden"]
      }
    end)
    |> Enum.sort_by(&{&1["profile"], &1["depth"], &1["workspace"]})
  end

  defp maybe_narrow_tools(config, bands) do
    case config[:tools] do
      nil -> {:ok, bands}
      tools -> Policy.narrow(bands, parse_tools_flag(tools))
    end
  end

  defp parse_tools_flag(tools) when is_list(tools), do: tools

  defp parse_tools_flag(tools) when is_binary(tools) do
    String.split(tools, ",", trim: true)
  end

  defp negotiable_or_human?(bands) do
    (bands["negotiable"] || []) != [] or (bands["human"] || []) != []
  end

  defp resolve_workspace(spec, loaded, state) do
    explicit =
      Map.get(spec, :workspace) ||
        spec.activation.workspace_id ||
        spec.activation.payload["workspace"]

    if explicit do
      explicit
    else
      attached = session_workspaces(state, spec)

      cond do
        attached != [] ->
          Enum.at(attached, 0)

        Map.has_key?(loaded.workspaces, "app") ->
          "app"

        true ->
          case Map.keys(loaded.workspaces) do
            [] -> "default"
            [only] -> only
            keys -> Enum.at(keys, 0)
          end
      end
    end
  end

  defp envelope_workspace_id(spec, policy_workspace) do
    if spec.depth == 0 do
      nil
    else
      Map.get(spec, :workspace_id) ||
        Map.get(spec, :workspace) ||
        spec.activation.workspace_id ||
        spec.activation.payload["workspace"] ||
        policy_workspace
    end
  end

  defp agent_context(state, spec, loaded \\ nil) do
    base = %{
      depth: spec.depth,
      max_depth: state.max_depth,
      attempt: spec.attempt,
      work_item: spec.work_item,
      comment: spec[:comment] || spec.activation.payload["comment"],
      checkpoint: spec.checkpoint,
      session_id: spec.session_id || spec.activation.session_id,
      workspace_id: envelope_workspace_id(spec, Map.get(spec, :workspace)),
      workspace: Map.get(spec, :workspace, spec.activation.workspace_id),
      team: Map.get(spec, :team, spec.activation.payload["team"]),
      agent: Map.get(spec, :agent, spec.activation.payload["agent"]),
      reason: Map.get(spec, :reason, "initial"),
      assessment: Map.get(spec, :assessment),
      flow: Omunculus.Runtime.Workflow.flow(state.core, spec.work_item_id),
      stage: Omunculus.Runtime.Workflow.stage(state.core, spec.work_item_id),
      cross_lineage_arbitration: Map.get(spec, :cross_lineage_arbitration),
      cross_lineage_request: Map.get(spec, :cross_lineage_request),
      execution: task_execution(state.core, spec),
      response_contract: Omunculus.Interception.Agents.contract(state.core, spec.work_item_id)
    }

    case loaded do
      nil ->
        base

      config ->
        base
        |> Map.put(:config, config)
        |> Map.put(:profile, resolve_profile(spec, config, state.config))
    end
  end

  defp resolve_profile(_spec, loaded, config) do
    config[:profile] || loaded.defaults.preset || "coding"
  end

  defp maybe_intersect_team_profile(loaded, spec, line_bands) do
    team_name = Map.get(spec, :team) || spec.activation.payload["team"]

    with name when is_binary(name) <- team_name,
         %{profile: team_profile} <- Map.get(loaded.teams, name, %{}),
         true <- is_binary(team_profile) and Map.has_key?(loaded.presets, team_profile),
         preset <- Map.get(loaded.presets, team_profile),
         {:ok, team_bands} <-
           Policy.normalize(preset[:policy] || %{},
             catalog_version: loaded.session[:tools_catalog]
           ) do
      {:ok, Policy.intersect(line_bands, team_bands)}
    else
      _ -> {:ok, line_bands}
    end
  end

  defp merge_config_tool_options(agent, loaded, spec, state) do
    workspaces =
      if spec.depth == 0 do
        attached_workspaces_snapshot(state, loaded, spec.session_id) || loaded.workspaces
      else
        loaded.workspaces
      end

    snapshot = %{
      workspaces: workspaces,
      teams: loaded.teams,
      agents: Map.merge(Omunculus.Runtime.Agents.defaults(), loaded.agents)
    }

    tool_options = Map.merge(Map.get(agent, :tool_options) || %{}, snapshot)

    directory_scope =
      Map.get(loaded, :policy, %{})
      |> Map.get(to_string(spec.depth), %{})
      |> Policy.directory_scope()

    tool_options =
      tool_options
      |> Map.put(:directory_scope, directory_scope)
      |> Map.put(:team, Map.get(spec, :team))
      |> Map.put(:workspace_id, Map.get(spec, :workspace))
      |> Map.put(:work_item_id, spec.work_item_id)
      |> Map.put(:session_id, spec.session_id)
      |> then(fn opts ->
        case Map.get(spec, :roots) do
          roots when is_list(roots) and roots != [] -> Map.put(opts, :roots, roots)
          _ -> opts
        end
      end)

    agent =
      agent
      |> Map.put(:tool_options, tool_options)
      |> Map.put(:directory_scope, directory_scope)

    if "directory" in (agent.tools || []) do
      Map.put(agent, :tool_options, Map.put(agent.tool_options, :core, state.core))
    else
      agent
    end
  end

  defp bands_from_tools(tools) do
    %{
      "granted" => tools,
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp normalize_runtime_config(nil), do: nil
  defp normalize_runtime_config([]), do: nil

  defp normalize_runtime_config(config) when is_list(config) do
    if Keyword.keyword?(config), do: Map.new(config), else: nil
  end

  defp normalize_runtime_config(config) when is_map(config) do
    if map_size(config) == 0, do: nil, else: config
  end

  defp normalize_runtime_config(_), do: nil

  defp initial_comment(spec, agent) do
    if spec[:reason] in [nil, "initial"] do
      step = List.first((agent[:flow] || %{})["steps"] || [])

      comment =
        [
          spec[:comment],
          if(spec.depth == 0 && agent[:task_instructions],
            do: "Task criteria: " <> agent.task_instructions
          ),
          if(step, do: "Current stage: #{step["name"]}. #{step["instructions"]}")
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")

      Map.put(spec, :comment, comment)
    else
      spec
    end
  end

  defp record_crash(core, run, reason) do
    EventCore.append!(
      core,
      Envelope.event("run.failed",
        session_id: run.session_id,
        correlation_id: run.correlation_id,
        causation_id: run.started_event_id || run.activation_id,
        work_item_id: run.work_item_id,
        run_id: run.run_id,
        payload: %{reason: inspect(reason), crashed: true}
      )
    )
  end

  # --- resume derived from the log -------------------------------------------------

  defp derive_resume(core, work_item_id) do
    history = EventCore.delivered_stream(core, 0, work_item_id: work_item_id)
    activation = find_activation(core, work_item_id)
    starts = Enum.filter(history, &(&1.type == "run.started"))
    last_start = List.last(starts)

    closed? =
      last_start &&
        Enum.any?(history, &(&1.run_id == last_start.run_id and &1.type in ["run.failed"]))

    completed? = Enum.any?(history, &(&1.type == "task.completed"))

    cond do
      is_nil(activation) ->
        {:error, :unknown_work_item}

      completed? ->
        {:error, :already_completed}

      is_nil(last_start) ->
        {:error, :never_started}

      not closed? ->
        {:error, :run_still_open}

      true ->
        checkpoint = Omunculus.Runtime.Workflow.checkpoint(core, work_item_id)

        p = last_start.payload

        {:ok,
         %{
           work_item_id: work_item_id,
           depth: p["depth"],
           attempt: length(starts) + 1,
           work_item: Omunculus.WorkItem.from_activation(activation),
           parent_run_id: p["parent_run_id"],
           originating_run_id: p["originating_run_id"],
           checkpoint: checkpoint,
           project_id: activation.project_id,
           session_id: activation.session_id,
           workspace: p["workspace"] || activation.payload["workspace"],
           workspace_id:
             if(p["depth"] > 0, do: p["workspace"] || activation.workspace_id, else: nil),
           node_id: p["node_id"],
           team: p["team"],
           reason: "retry"
         }}
    end
  end

  defp find_activation(core, work_item_id) do
    case EventCore.delivered_stream(core, 0,
           work_item_id: work_item_id,
           type: "task.requested",
           limit: 1
         ) do
      [env] ->
        env

      [] ->
        core
        |> EventCore.delivered_stream(0, type: "task.delegated")
        |> Enum.find(&(&1.payload["child_work_item_id"] == work_item_id))
    end
  end

  # pending_continuations is rebuilt from WORK_ITEMS on init (see rebuild_pending_continuations/1).
  defp find_parent_waiter(core, child_work_item_id) do
    child = to_string(child_work_item_id)

    parent_wi =
      case find_parent_in_projection(core, child) do
        {:ok, parent_wi} -> parent_wi
        :error -> parent_work_item_id(core, child)
      end

    with parent_wi when is_binary(parent_wi) <- parent_wi,
         %Envelope{payload: %{"outcome" => "waiting"}} = run_completed <-
           EventCore.delivered_stream(core, 0, work_item_id: parent_wi, type: "run.completed")
           |> List.last()
           |> waiting_report() do
      {:ok, parent_wi, run_completed}
    else
      _ -> :error
    end
  end

  defp waiting_report(
         %Envelope{payload: %{"outcome" => "reported", "assessment" => review}} = env
       )
       when is_map(review) do
    checkpoint = review["restore"] || %{}

    %{
      env
      | payload:
          Map.merge(env.payload, %{
            "outcome" => "waiting",
            "checkpoint" => checkpoint,
            "awaiting" => checkpoint["awaiting"] || []
          })
    }
  end

  defp waiting_report(%Envelope{payload: %{"outcome" => "reported", "checkpoint" => cp}} = env) do
    if cp["awaiting"] != [],
      do: %{
        env
        | payload: Map.merge(env.payload, %{"outcome" => "waiting", "awaiting" => cp["awaiting"]})
      },
      else: env
  end

  defp waiting_report(env), do: env

  defp find_parent_in_projection(core, child) do
    waiting_rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE state = ?",
        ["waiting"]
      )

    # Continuation runs flip state to running while awaiting stays on WORK_ITEMS.
    running_rows =
      EventCore.query(
        core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE state = ? AND awaiting IS NOT NULL AND awaiting != '' AND awaiting != '[]'",
        ["running"]
      )

    case Enum.find(waiting_rows ++ running_rows, fn [_parent_wi, awaiting] ->
           case decode_awaiting(awaiting) do
             ids when is_list(ids) -> child in Enum.map(ids, &to_string/1)
             _ -> false
           end
         end) do
      [parent_wi, _] -> {:ok, parent_wi}
      nil -> :error
    end
  end

  defp parent_work_item_id(core, child) do
    case EventCore.query(
           core,
           "SELECT parent_work_item_id FROM WORK_ITEMS WHERE work_item_id = ?",
           [child]
         ) do
      [[parent_wi]] when is_binary(parent_wi) -> parent_wi
      _ -> nil
    end
  end

  defp decode_awaiting(nil), do: nil
  defp decode_awaiting(""), do: nil
  defp decode_awaiting(ids) when is_list(ids), do: ids

  defp decode_awaiting(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, ids} -> ids
      _ -> nil
    end
  end

  defp continue_parent(state, env, parent_wi, checkpoint, child_id, awaiting) do
    pending = checkpoint["pending"] || %{}

    tool_call_id =
      pending[child_id] ||
        pending[env.work_item_id] ||
        pending |> Map.values() |> List.first() ||
        "call_delegate"

    new_awaiting = Enum.reject(awaiting, &(to_string(&1) == child_id))

    pending_text =
      case new_awaiting do
        [] -> "none"
        ids -> Enum.map_join(ids, ", ", &to_string/1)
      end

    observation = %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" =>
        "Sub-agent completed. Result: #{env.payload["result"]}. Still pending: #{pending_text}"
    }

    new_pending =
      pending
      |> Map.delete(child_id)
      |> Map.delete(env.work_item_id)

    new_checkpoint =
      checkpoint
      |> Map.put("messages", (checkpoint["messages"] || []) ++ [observation])
      |> Map.put("awaiting", new_awaiting)
      |> Map.put("pending", new_pending)

    last_start =
      events(state, work_item_id: parent_wi, type: "run.started")
      |> List.last()

    attempt =
      events(state, work_item_id: parent_wi, type: "run.started")
      |> length()
      |> Kernel.+(1)

    activation = find_activation(state.core, parent_wi)

    start_run(state, %{
      activation: env,
      work_item_id: parent_wi,
      correlation_id: env.correlation_id,
      depth: last_start.payload["depth"],
      attempt: attempt,
      work_item: Omunculus.WorkItem.from_activation(activation),
      parent_run_id: last_start.payload["parent_run_id"],
      originating_run_id: last_start.payload["originating_run_id"],
      checkpoint: new_checkpoint,
      project_id: env.project_id,
      session_id: env.session_id,
      workspace: last_start.payload["workspace"],
      workspace_id:
        if(last_start.payload["depth"] > 0,
          do: last_start.payload["workspace"] || env.workspace_id,
          else: nil
        ),
      node_id: last_start.payload["node_id"],
      team: last_start.payload["team"],
      agent: last_start.payload["agent_id"],
      reason: if(new_checkpoint["assessment"], do: "assessment", else: "continuation"),
      assessment: new_checkpoint["assessment"]
    })
  end

  defp live_run_for_work_item?(state, work_item_id, except_run_id \\ nil) do
    Enum.any?(state.runs, fn {run_id, run} ->
      run.work_item_id == work_item_id and run_id != except_run_id
    end)
  end

  defp queue_continuation(state, parent_wi, env) do
    queue = Map.get(state.pending_continuations, parent_wi, [])

    %{
      state
      | pending_continuations: Map.put(state.pending_continuations, parent_wi, queue ++ [env])
    }
  end

  defp maybe_continue_parent(
         state,
         work_item_id,
         env \\ nil,
         run_completed \\ nil,
         child_id \\ nil,
         awaiting \\ nil
       ) do
    cond do
      env ->
        if live_run_for_work_item?(state, work_item_id) do
          queue_continuation(state, work_item_id, env)
        else
          continue_parent(
            state,
            env,
            work_item_id,
            run_completed.payload["checkpoint"] || %{},
            child_id,
            awaiting
          )
        end

      true ->
        case Map.get(state.pending_continuations, work_item_id, []) do
          [] ->
            state

          [next | rest] ->
            pending =
              if rest == [],
                do: Map.delete(state.pending_continuations, work_item_id),
                else: Map.put(state.pending_continuations, work_item_id, rest)

            state = %{state | pending_continuations: pending}

            case find_parent_waiter(state.core, next.work_item_id) do
              {:ok, parent_wi, run_completed} ->
                checkpoint = run_completed.payload["checkpoint"] || %{}
                awaiting = checkpoint["awaiting"] || []
                child_id = to_string(next.work_item_id)

                if child_id in Enum.map(awaiting, &to_string/1) do
                  maybe_continue_parent(state, parent_wi, next, run_completed, child_id, awaiting)
                else
                  state
                end

              :error ->
                state
            end
        end
    end
  end

  # --- root wait ---------------------------------------------------------------------

  defp wait_root(core, requested, timeout, return_on_human) do
    already =
      core
      |> EventCore.delivered_stream(0,
        work_item_id: requested.work_item_id,
        type: "task.completed",
        limit: 1
      )
      |> List.first()

    completed =
      case already do
        %Envelope{} = env ->
          {:ok, env}

        nil ->
          wid = requested.work_item_id
          requested_id = requested.event_id

          receive do
            {:event_core, %Envelope{type: "task.completed", work_item_id: ^wid} = env} ->
              {:ok, env}

            {:event_core,
             %Envelope{
               type: "task.commented",
               work_item_id: ^wid,
               payload: %{"kind" => "request", "assessment" => true}
             } = env}
            when return_on_human ->
              {:error, {:awaiting_human, env.payload["body"]}}

            {:event_core,
             %Envelope{type: "interception.requested", payload: %{"actor" => "human"}} = env}
            when return_on_human ->
              {:error, {:awaiting_human, "Interceptor #{env.payload["name"]}: #{env.event_id}"}}

            {:event_core, %Envelope{type: "run.failed", work_item_id: ^wid} = env} ->
              {:error, {:run_failed, env.payload}}

            {:event_core, %Envelope{type: "delivery.rejected", causation_id: ^requested_id} = env} ->
              {:error, {:delivery_rejected, env.payload["reason"]}}
          after
            timeout -> {:error, :timeout}
          end
      end

    case completed do
      {:ok, env} ->
        {:ready, delivered} = EventCore.delivery(core, env)
        {:ok, %{result: delivered.payload["result"], requested: requested, completed: delivered}}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_put_workspace_payload(payload, nil), do: payload

  defp maybe_put_workspace_payload(payload, workspace),
    do: Map.put(payload, :workspace, workspace)

  defp session_workspaces(state, spec) do
    session_id = spec.session_id || spec.activation.session_id

    if is_binary(session_id) and match?(%{core: _}, state) do
      attached_session_workspaces(state.core, session_id)
    else
      []
    end
  end

  defp attached_session_workspaces(core, session_id) do
    with true <- projection_table?(core, "SESSION_WORKSPACES"),
         {:ok, sql, args} <- session_workspaces_query(core, session_id),
         rows when is_list(rows) <- safe_event_core_query(core, sql, args) do
      Enum.flat_map(rows, fn
        [ws] when is_binary(ws) -> [ws]
        _ -> []
      end)
    else
      _ -> []
    end
  end

  defp projection_table?(core, table) do
    case safe_event_core_query(
           core,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
           [table]
         ) do
      [[1]] -> true
      _ -> false
    end
  end

  defp session_workspaces_query(_core, session_id),
    do:
      {:ok,
       "SELECT workspace_id FROM SESSION_WORKSPACES WHERE session_id = ? AND attached = 1 ORDER BY workspace_id",
       [session_id]}

  defp safe_event_core_query(core, sql, args) do
    try do
      EventCore.query(core, sql, args)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp assign_node_id(state, spec, loaded) do
    node_id =
      Map.get(spec, :node_id) ||
        node_id_from_last_start(state, spec) ||
        compute_node_id(spec, loaded)

    key = node_cache_key(spec, loaded)
    nodes = if key, do: Map.put(state.nodes, key, node_id), else: state.nodes
    {Map.put(spec, :node_id, node_id), %{state | nodes: nodes}}
  end

  defp node_id_from_last_start(state, spec) do
    case events(state, work_item_id: spec.work_item_id, type: "run.started")
         |> List.last() do
      %Envelope{payload: %{"node_id" => node_id}} when is_binary(node_id) -> node_id
      _ -> nil
    end
  end

  defp compute_node_id(spec, loaded) do
    session_id = spec.session_id || spec.activation.session_id

    case spec.depth do
      0 ->
        hash_node_id([session_id, 0])

      1 ->
        workspace = Map.get(spec, :workspace) || spec.activation.workspace_id
        team = Map.get(spec, :team) || spec.activation.payload["team"]

        if team_scope_node?(loaded, team),
          do: hash_node_id([session_id, workspace, team, 1]),
          else: hash_node_id([session_id, workspace, 1])

      _ ->
        Envelope.generate_id("node")
    end
  end

  defp node_cache_key(spec, loaded) do
    session_id = spec.session_id || spec.activation.session_id

    case spec.depth do
      0 ->
        {:depth0, session_id}

      1 ->
        workspace = Map.get(spec, :workspace) || spec.activation.workspace_id
        team = Map.get(spec, :team) || spec.activation.payload["team"]

        if team_scope_node?(loaded, team),
          do: {:depth1, session_id, workspace, team},
          else: {:depth1, session_id, workspace}

      _ ->
        {:depthn, spec.work_item_id}
    end
  end

  defp team_scope_node?(loaded, team) when is_binary(team) do
    case loaded do
      %{teams: teams} ->
        case Map.get(teams, team, %{}) do
          %{scope: "node"} -> true
          %{"scope" => "node"} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp team_scope_node?(_, _), do: false

  defp hash_node_id(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("node_" <> String.slice(&1, 0, 16)))
  end

  defp rebuild_pending_continuations(state) do
    waiting_rows =
      EventCore.query(
        state.core,
        "SELECT work_item_id, awaiting FROM WORK_ITEMS WHERE state = ?",
        ["waiting"]
      )

    pending =
      Enum.reduce(waiting_rows, %{}, fn [parent_wi, awaiting_json], acc ->
        with ids when is_list(ids) <- decode_awaiting(awaiting_json),
             %Envelope{payload: %{"outcome" => "waiting"}} = run_completed <-
               events(state, work_item_id: parent_wi, type: "run.completed")
               |> List.last()
               |> waiting_report(),
             true <- is_nil(state[:session_id]) or run_completed.session_id == state.session_id,
             checkpoint_awaiting <- run_completed.payload["checkpoint"]["awaiting"] || [] do
          Enum.reduce(ids, acc, fn child_id, inner ->
            child = to_string(child_id)

            if child in Enum.map(checkpoint_awaiting, &to_string/1) and
                 task_completed?(state.core, child) do
              case events(state, work_item_id: child, type: "task.completed")
                   |> List.last() do
                %Envelope{} = env -> Map.update(inner, parent_wi, [env], &(&1 ++ [env]))
                _ -> inner
              end
            else
              inner
            end
          end)
        else
          _ -> acc
        end
      end)

    %{state | pending_continuations: pending}
  end

  defp task_completed?(core, work_item_id),
    do: Omunculus.Runtime.Workflow.completed?(core, work_item_id)

  defp flush_pending_continuations(state) do
    Enum.reduce(Map.keys(state.pending_continuations), state, fn parent_wi, acc ->
      maybe_continue_parent(acc, parent_wi)
    end)
  end

  defp register_attached_nodes(state, env) do
    session_id = env.session_id
    workspace_id = env.payload["workspace_id"]

    if is_binary(session_id) and is_binary(workspace_id) do
      loaded = loaded_config(state)
      key = {:depth1, session_id, workspace_id}
      nodes = Map.put(state.nodes, key, hash_node_id([session_id, workspace_id, 1]))

      nodes =
        Enum.reduce(node_scoped_teams(env, loaded, workspace_id), nodes, fn team, acc ->
          Map.put(
            acc,
            {:depth1, session_id, workspace_id, team},
            hash_node_id([session_id, workspace_id, team, 1])
          )
        end)

      %{state | nodes: nodes}
    else
      state
    end
  end

  defp fail_runs_in_workspace(state, workspace_id, session_id) when is_binary(workspace_id) do
    Enum.reduce(state.runs, state, fn {_run_id, run}, acc ->
      if run.workspace_id == workspace_id and run.session_id == session_id do
        terminate_and_fail_run(acc, run, "detached")
      else
        acc
      end
    end)
  end

  defp fail_runs_in_workspace(state, _workspace_id, _session_id), do: state

  defp terminate_and_fail_run(state, run, reason) do
    if Process.alive?(run.pid), do: DynamicSupervisor.terminate_child(state.sup, run.pid)

    record_run_failed(state.core, run, reason)

    runs = Map.delete(state.runs, run.run_id)
    pids = Map.delete(state.pids, run.pid)
    %{state | runs: runs, pids: pids}
  end

  defp record_run_failed(core, run, reason) do
    EventCore.append!(
      core,
      Envelope.event("run.failed",
        session_id: run.session_id,
        correlation_id: run.correlation_id,
        causation_id: run.started_event_id || run.activation_id,
        work_item_id: run.work_item_id,
        run_id: run.run_id,
        workspace_id: run.workspace_id,
        payload: %{reason: reason}
      )
    )
  end

  defp workspace_roots(state, workspace, loaded, session_id) do
    case attached_workspace_row(state.core, workspace, session_id) do
      {:ok, roots, _teams} ->
        roots

      :error ->
        entry = Map.get(loaded.workspaces, workspace, %{})

        Enum.map(
          entry[:roots] || entry["roots"] || [],
          &Path.expand(&1, (state.config || %{})[:cwd] || File.cwd!())
        )
    end
  end

  defp attached_workspaces_snapshot(state, loaded, session_id) do
    case attached_workspace_rows(state.core, session_id) do
      [] ->
        nil

      rows ->
        Map.new(rows, fn {ws_id, roots, teams} ->
          base = Map.get(loaded.workspaces, ws_id, %{})

          entry =
            base
            |> Map.put(:roots, roots)
            |> Map.put(:teams, teams)

          {ws_id, entry}
        end)
    end
  end

  defp attached_workspace_row(core, workspace_id, session_id) do
    case Enum.find(attached_workspace_rows(core, session_id), fn {ws_id, _, _} ->
           ws_id == workspace_id
         end) do
      {_ws_id, roots, teams} -> {:ok, roots, teams}
      nil -> :error
    end
  end

  defp attached_workspace_rows(core, session_id) do
    unless projection_table?(core, "SESSION_WORKSPACES"), do: []

    EventCore.query(
      core,
      "SELECT workspace_id, roots, teams FROM SESSION_WORKSPACES WHERE session_id = ? AND attached = 1 ORDER BY workspace_id",
      [session_id || ""]
    )
    |> Enum.flat_map(fn
      [ws_id, roots_json, teams_json] ->
        [{ws_id, decode_json_list(roots_json), decode_json_list(teams_json)}]

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp decode_json_list(nil), do: []

  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(list) when is_list(list), do: list
  defp decode_json_list(_), do: []

  defp node_scoped_teams(env, loaded, workspace_id) do
    teams =
      env.payload["teams"] ||
        case loaded do
          %{workspaces: workspaces} ->
            case Map.get(workspaces, workspace_id, %{}) do
              %{teams: teams} -> teams
              %{"teams" => teams} -> teams
              _ -> []
            end

          _ ->
            []
        end

    Enum.filter(List.wrap(teams), &team_scope_node?(loaded, &1))
  end

  defp waiting_snapshot(core, work_item_id) do
    case EventCore.query(
           core,
           "SELECT awaiting, checkpoint FROM WORK_ITEMS WHERE work_item_id = ?",
           [work_item_id]
         ) do
      [[awaiting_json, checkpoint_json]] ->
        %{
          awaiting: decode_awaiting(awaiting_json) || [],
          checkpoint: decode_checkpoint(checkpoint_json) || %{}
        }

      _ ->
        %{awaiting: [], checkpoint: %{}}
    end
  end

  defp decode_checkpoint(nil), do: %{}
  defp decode_checkpoint(""), do: %{}

  defp decode_checkpoint(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_checkpoint(map) when is_map(map), do: map

  defp start_arbitration_run(state, perm_env) do
    child_wi = perm_env.work_item_id

    with parent_wi when is_binary(parent_wi) <- parent_work_item_id(state.core, child_wi),
         %Envelope{payload: parent_start} <-
           events(state, work_item_id: parent_wi, type: "run.started")
           |> List.last() do
      tool = perm_env.payload["tool"]
      reason = perm_env.payload["reason"]
      request_id = perm_env.payload["request_id"]

      instruction = """
      A child work item (#{child_wi}) requests permission to use `#{tool}`.
      Reason: #{reason}
      Use grant, deny, or escalate.
      """

      attempt =
        events(state, work_item_id: parent_wi, type: "run.started")
        |> length()
        |> Kernel.+(1)

      loaded = loaded_config(state)
      restore = waiting_snapshot(state.core, parent_wi)

      spec = %{
        activation: perm_env,
        work_item_id: parent_wi,
        correlation_id: perm_env.correlation_id,
        depth: parent_start["depth"],
        attempt: attempt,
        work_item: Omunculus.WorkItem.load(state.core, parent_wi),
        comment: instruction,
        parent_run_id: parent_start["parent_run_id"],
        originating_run_id: parent_start["originating_run_id"],
        checkpoint: %{},
        project_id: perm_env.project_id,
        session_id: perm_env.session_id,
        workspace: parent_start["workspace"],
        workspace_id:
          if(parent_start["depth"] > 0,
            do: parent_start["workspace"] || perm_env.workspace_id,
            else: nil
          ),
        node_id: parent_start["node_id"],
        team: parent_start["team"],
        reason: "arbitration",
        arbitration: true,
        arbitration_request_id: request_id,
        arbitration_child_wi: child_wi,
        arbitration_restore: restore,
        request_permission: false
      }

      agent = arbitration_agent(state, spec, loaded)
      bands = arbitration_bands()

      start_run_with_agent(state, spec, agent, bands, nil, false)
    else
      _ -> state
    end
  end

  defp arbitration_agent(state, spec, loaded) do
    ctx = agent_context(state, spec, loaded)
    agent = state.agents.(ctx)
    %{agent | tools: ["grant", "deny", "escalate"]}
  end

  defp arbitration_bands do
    %{
      "granted" => ["grant", "deny", "escalate"],
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp reopen_permission_wait(state, resolution_env, work_item_id, request_id) do
    run_completed =
      events(state, work_item_id: work_item_id, type: "run.completed")
      |> Enum.filter(&(Map.get(&1.payload, "outcome") == "waiting"))
      |> List.last()

    with %Envelope{} <- run_completed,
         checkpoint when is_map(checkpoint) <- run_completed.payload["checkpoint"] || %{} do
      observation = RuntimePermission.resolution_observation(state.core, request_id)

      reopen_permission_continuation(
        state,
        resolution_env,
        work_item_id,
        checkpoint,
        request_id,
        observation
      )
    else
      _ -> state
    end
  end

  defp reopen_policy_wait(state, env, except_run_id) do
    work_item_id = env.work_item_id

    if live_run_for_work_item?(state, work_item_id, except_run_id) do
      state
    else
      checkpoint = env.payload["checkpoint"] || %{}
      reopen_permission_continuation(state, env, work_item_id, checkpoint, "policy", nil)
    end
  end

  defp reopen_permission_continuation(
         state,
         causation_env,
         work_item_id,
         checkpoint,
         await_key,
         observation
       ) do
    awaiting = checkpoint["awaiting"] || []

    if to_string(await_key) in Enum.map(awaiting, &to_string/1) do
      new_awaiting = Enum.reject(awaiting, &(to_string(&1) == to_string(await_key)))

      new_checkpoint =
        checkpoint
        |> Map.put("awaiting", new_awaiting)
        |> maybe_append_permission_observation(observation, await_key)

      last_start =
        events(state, work_item_id: work_item_id, type: "run.started")
        |> List.last()

      attempt =
        events(state, work_item_id: work_item_id, type: "run.started")
        |> length()
        |> Kernel.+(1)

      activation = find_activation(state.core, work_item_id)

      start_run(state, %{
        activation: causation_env,
        work_item_id: work_item_id,
        correlation_id: causation_env.correlation_id,
        depth: last_start.payload["depth"],
        attempt: attempt,
        work_item: Omunculus.WorkItem.from_activation(activation),
        parent_run_id: last_start.payload["parent_run_id"],
        originating_run_id: last_start.payload["originating_run_id"],
        checkpoint: new_checkpoint,
        project_id: causation_env.project_id,
        session_id: causation_env.session_id,
        workspace: last_start.payload["workspace"],
        workspace_id:
          if(last_start.payload["depth"] > 0,
            do: last_start.payload["workspace"] || causation_env.workspace_id,
            else: nil
          ),
        node_id: last_start.payload["node_id"],
        team: last_start.payload["team"],
        agent: last_start.payload["agent_id"],
        reason: "continuation",
        request_permission: true
      })
    else
      state
    end
  end

  defp maybe_append_permission_observation(checkpoint, nil, _await_key), do: checkpoint
  defp maybe_append_permission_observation(checkpoint, "", _await_key), do: checkpoint

  defp maybe_append_permission_observation(checkpoint, observation, await_key) do
    tool_call_id = permission_tool_call_id(checkpoint, await_key)

    observation_msg = %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => observation
    }

    Map.put(checkpoint, "messages", (checkpoint["messages"] || []) ++ [observation_msg])
  end

  defp permission_tool_call_id(checkpoint, await_key) do
    pending = checkpoint["pending"] || %{}

    Map.get(pending, to_string(await_key)) ||
      Map.get(pending, await_key) ||
      find_request_permission_call_id(checkpoint["messages"] || []) ||
      "call_request_permission"
  end

  defp find_request_permission_call_id(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
        Enum.find_value(calls, fn call ->
          fn_block = call["function"] || call[:function] || %{}
          name = fn_block["name"] || fn_block[:name] || call["name"]

          if name == "request_permission" do
            call["id"] || call[:id]
          end
        end)

      _ ->
        nil
    end)
  end

  defp grant_open_requests_by_policy(state, env) do
    case state.config do
      nil ->
        state

      config ->
        RuntimePermission.open_permission_requests(state.core)
        |> Enum.filter(&(&1.session_id == env.session_id))
        |> Enum.reduce(state, fn req_env, st ->
          tool = req_env.payload["tool"]
          workspace = req_env.payload["workspace"]

          spec = %{
            depth: work_item_depth(st.core, req_env.work_item_id),
            workspace: workspace,
            activation: req_env
          }

          if RuntimePermission.tool_granted_by_policy?(config, spec, tool) do
            EventCore.append!(
              st.core,
              Envelope.command("permission.granted",
                session_id: req_env.session_id,
                correlation_id: req_env.correlation_id,
                causation_id: env.event_id,
                work_item_id: req_env.work_item_id,
                payload: %{
                  request_id: req_env.payload["request_id"],
                  kind: "permanent",
                  granter: "policy"
                }
              )
            )

            st
          else
            st
          end
        end)
    end
  end

  defp work_item_depth(core, work_item_id) do
    case EventCore.delivered_stream(core, 0, work_item_id: work_item_id, type: "run.started")
         |> List.last() do
      %Envelope{payload: %{"depth" => depth}} when is_integer(depth) -> depth
      %Envelope{payload: %{"depth" => depth}} when is_binary(depth) -> String.to_integer(depth)
      _ -> 0
    end
  end

  defp loaded_config(state) do
    case state.config do
      nil ->
        nil

      config ->
        load_opts = [
          cwd: config[:cwd] || File.cwd!(),
          config_file: config[:config_file],
          env: config[:env] || %{}
        ]

        case Config.load(load_opts) do
          {:ok, loaded} -> loaded
          _ -> nil
        end
    end
  end

  defp route_request_work(state, env) do
    already_routed? =
      Enum.any?(
        events(state, type: "task.delegated"),
        &(&1.payload["child_work_item_id"] == env.payload["child_work_item_id"])
      )

    if already_routed?, do: state, else: do_route_request_work(state, env)
  end

  defp do_route_request_work(state, env) do
    loaded = loaded_config(state)
    mode = cross_lineage_mode(loaded)
    requester_wi = env.work_item_id
    lca_wi = lca_work_item_id(state.core, requester_wi, env.payload)

    case mode do
      "mediated" ->
        if live_run_for_work_item?(state, lca_wi),
          do: state,
          else: start_cross_lineage_arbitration(state, env, lca_wi, loaded)

      _ ->
        forward_request_work(state, env, lca_wi, env.payload["work_item"])
    end
  end

  defp recover_cross_requests(state) do
    events = events(state)

    Enum.reduce(events, state, fn req, acc ->
      if req.type == "task.requested" and Map.has_key?(req.payload, "requested_by") do
        rejected =
          Enum.any?(events, &(&1.type == "delivery.rejected" and &1.causation_id == req.event_id))

        delegated =
          Enum.any?(
            events,
            &(&1.type == "task.delegated" and
                &1.payload["child_work_item_id"] == req.payload["child_work_item_id"])
          )

        decision =
          Enum.find(
            events,
            &(&1.type == "run.completed" and &1.payload["request_event_id"] == req.event_id)
          )

        active = Enum.any?(acc.runs, fn {_, run} -> run.activation_id == req.event_id end)

        cond do
          rejected or delegated or active ->
            acc

          decision && decision.payload["cross_lineage_denied"] ->
            maybe_reopen_cross_lineage_denial(
              acc,
              decision,
              decision.payload["cross_lineage_denied"]
            )

          decision ->
            acc

          true ->
            route_request_work(acc, req)
        end
      else
        acc
      end
    end)
  end

  defp cross_lineage_mode(nil), do: "routed"

  defp cross_lineage_mode(loaded) do
    loaded.session[:cross_lineage] || loaded.session["cross_lineage"] || "routed"
  end

  defp forward_request_work(state, env, lca_wi, work_item) do
    payload = env.payload

    with %Envelope{payload: lca_start, run_id: lca_run_id} <- last_run_started(state.core, lca_wi) do
      delegated =
        Envelope.event("task.delegated",
          idempotency_key: "route:" <> env.event_id,
          correlation_id: env.correlation_id,
          causation_id: env.event_id,
          session_id: env.session_id,
          workspace_id: payload["workspace"] || env.workspace_id,
          project_id: env.project_id,
          work_item_id: lca_wi,
          run_id: lca_run_id,
          payload: %{
            "recovery" => payload["recovery"],
            "work_item" => work_item,
            "comment" => payload["comment"],
            "child_work_item_id" => payload["child_work_item_id"],
            "to_depth" => target_depth(payload, lca_start["depth"], loaded_config(state)),
            "parent_run_id" => lca_run_id,
            "originating_run_id" => lca_start["originating_run_id"],
            "team" => payload["team"],
            "agent" => payload["agent"],
            "workspace" => payload["workspace"],
            "requested_by" => payload["requested_by"],
            "requester_work_item_id" => payload["requester_work_item_id"] || requester_wi(env)
          }
        )

      EventCore.append!(state.core, delegated)
    end

    state
  end

  defp requester_wi(env), do: env.work_item_id

  defp target_depth(payload, lca_depth, loaded) do
    team = if loaded, do: Map.get(loaded.teams, payload["team"], %{}), else: %{}

    if payload["agent"] && payload["agent"] != team[:lead],
      do: max(lca_depth + 1, 2),
      else: max(lca_depth + 1, 1)
  end

  defp lca_work_item_id(core, requester_wi, payload) do
    requester_team = work_item_team(core, requester_wi)
    requester_ws = work_item_workspace(core, requester_wi)
    target_ws = payload["workspace"] || requester_ws
    target_team = payload["team"]
    target_agent = payload["agent"]

    cond do
      is_binary(target_ws) and is_binary(requester_ws) and target_ws != requester_ws ->
        root_work_item_id(core, requester_wi)

      is_binary(target_team) and target_team != "" and target_team != requester_team ->
        root_work_item_id(core, requester_wi)

      is_binary(target_agent) and target_agent != "" ->
        parent_work_item_id(core, requester_wi) || root_work_item_id(core, requester_wi)

      true ->
        root_work_item_id(core, requester_wi)
    end
  end

  defp root_work_item_id(core, work_item_id) do
    case parent_chain(core, work_item_id) do
      [] -> work_item_id
      chain -> List.last(chain)
    end
  end

  defp parent_chain(core, work_item_id) do
    Stream.unfold(work_item_id, fn wi ->
      case parent_work_item_id(core, wi) do
        nil -> nil
        parent -> {parent, parent}
      end
    end)
    |> Enum.to_list()
  end

  defp work_item_team(core, work_item_id) do
    case last_run_started(core, work_item_id) do
      %Envelope{payload: %{"team" => team}} when is_binary(team) -> team
      _ -> nil
    end
  end

  defp work_item_workspace(core, work_item_id) do
    case EventCore.query(core, "SELECT workspace_id FROM WORK_ITEMS WHERE work_item_id = ?", [
           work_item_id
         ]) do
      [[ws]] when is_binary(ws) ->
        ws

      _ ->
        case last_run_started(core, work_item_id) do
          %Envelope{payload: %{"workspace" => ws}} when is_binary(ws) -> ws
          _ -> nil
        end
    end
  end

  defp last_run_started(core, work_item_id) do
    EventCore.delivered_stream(core, 0, work_item_id: work_item_id, type: "run.started")
    |> List.last()
  end

  defp start_cross_lineage_arbitration(state, env, lca_wi, loaded) do
    with %Envelope{payload: lca_start} <- last_run_started(state.core, lca_wi) do
      instruction = cross_lineage_arbitration_instruction(env)

      attempt =
        events(state, work_item_id: lca_wi, type: "run.started")
        |> length()
        |> Kernel.+(1)

      spec = %{
        activation: env,
        work_item_id: lca_wi,
        correlation_id: env.correlation_id,
        depth: lca_start["depth"],
        attempt: attempt,
        work_item: Omunculus.WorkItem.load(state.core, lca_wi),
        comment: instruction,
        parent_run_id: lca_start["parent_run_id"],
        originating_run_id: lca_start["originating_run_id"],
        checkpoint: %{},
        project_id: env.project_id,
        session_id: env.session_id,
        workspace: lca_start["workspace"],
        workspace_id:
          if(lca_start["depth"] > 0,
            do: lca_start["workspace"] || env.workspace_id,
            else: nil
          ),
        node_id: lca_start["node_id"],
        team: lca_start["team"],
        reason: "arbitration",
        cross_lineage_arbitration: true,
        arbitration_restore: waiting_snapshot(state.core, lca_wi),
        cross_lineage_request: env,
        cross_lineage_work_item: env.payload["work_item"],
        cross_lineage_target_depth: target_depth(env.payload, lca_start["depth"], loaded),
        request_permission: false
      }

      ctx = agent_context(state, spec, loaded)
      agent = state.agents.(ctx)
      agent = merge_config_tool_options(agent, loaded, spec, state)
      agent = %{agent | tools: ["forward", "rewrite", "deny"]}
      bands = cross_lineage_arbitration_bands()

      start_run_with_agent(state, spec, agent, bands, nil, false)
    else
      _ -> state
    end
  end

  defp cross_lineage_arbitration_instruction(env) do
    payload = env.payload

    """
    A cross-lineage work request needs mediation.
    Work Item: #{Jason.encode!(payload["work_item"])}
    Comment: #{payload["comment"]}
    Target team: #{payload["team"] || "-"}
    Target agent: #{payload["agent"] || "-"}
    Use forward, rewrite, or deny.
    """
  end

  defp cross_lineage_arbitration_bands do
    %{
      "granted" => ["forward", "rewrite", "deny"],
      "negotiable" => [],
      "human" => [],
      "forbidden" => []
    }
  end

  defp maybe_reopen_cross_lineage_denial(state, env, reason) do
    req = find_cross_lineage_request(state.core, env)

    with %Envelope{} = req,
         requester_wi <- req.payload["requester_work_item_id"] || req.work_item_id,
         {:ok, _parent_wi, run_completed} <-
           find_parent_waiter(state.core, req.payload["child_work_item_id"]) do
      child_id = to_string(req.payload["child_work_item_id"])
      checkpoint = run_completed.payload["checkpoint"] || %{}
      awaiting = checkpoint["awaiting"] || []

      if child_id in Enum.map(awaiting, &to_string/1) and
           not live_run_for_work_item?(state, requester_wi) do
        observation = %{
          "role" => "tool",
          "tool_call_id" => cross_lineage_tool_call_id(checkpoint),
          "content" => "Cross-lineage request denied: #{reason}"
        }

        new_checkpoint =
          checkpoint
          |> Map.put("messages", (checkpoint["messages"] || []) ++ [observation])
          |> Map.put("awaiting", Enum.reject(awaiting, &(to_string(&1) == child_id)))

        reopen_requester_after_denial(state, req, requester_wi, new_checkpoint)
      else
        state
      end
    else
      _ -> state
    end
  end

  defp find_cross_lineage_request(core, arbitration_env) do
    case EventCore.fetch(core, arbitration_env.payload["request_event_id"]) do
      {:ok, req} -> req
      _ -> nil
    end
  end

  defp cross_lineage_tool_call_id(checkpoint) do
    pending = checkpoint["pending"] || %{}

    Map.get(pending, "request_work") ||
      Map.get(pending, :request_work) ||
      Map.values(pending) |> List.first() ||
      "call_request_work"
  end

  defp reopen_requester_after_denial(state, causation_env, work_item_id, checkpoint) do
    last_start =
      events(state, work_item_id: work_item_id, type: "run.started")
      |> List.last()

    attempt =
      events(state, work_item_id: work_item_id, type: "run.started")
      |> length()
      |> Kernel.+(1)

    activation = find_activation(state.core, work_item_id)

    start_run(state, %{
      activation: causation_env,
      work_item_id: work_item_id,
      correlation_id: causation_env.correlation_id,
      depth: last_start.payload["depth"],
      attempt: attempt,
      work_item: Omunculus.WorkItem.from_activation(activation),
      parent_run_id: last_start.payload["parent_run_id"],
      originating_run_id: last_start.payload["originating_run_id"],
      checkpoint: checkpoint,
      project_id: causation_env.project_id,
      session_id: causation_env.session_id,
      workspace: last_start.payload["workspace"],
      workspace_id:
        if(last_start.payload["depth"] > 0,
          do: last_start.payload["workspace"] || causation_env.workspace_id,
          else: nil
        ),
      node_id: last_start.payload["node_id"],
      team: last_start.payload["team"],
      agent: last_start.payload["agent_id"],
      reason: "continuation"
    })
  end
end
