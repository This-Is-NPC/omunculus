defmodule Omunculus.Run do
  @moduledoc """
  Opens a run with freshly assembled context and permissions, inside the
  project's `Omunculus.Cycle` (one of its own when there is none, so
  `open/2` then returns after every run this one opened, transitively,
  has finished). The run holds a slot of the `run` class of the execution
  limiter, bounded by `[execution]` `max_concurrent`, `max_queue` and
  `queue_timeout_ms`, from before its opening until after its follow-up.
  A work
  runs with its stage's agent, or without a stage with its assignee. A
  named reaction agent still obeys the work's stage and workflow-only
  flags. The agent's `model` from config is constructed via `new/1`. The
  assembled prompt (`Omunculus.Prompt`) is the `instructions` and the
  `output` of the tool named by `agents.<x>.assemble` or
  `[policy] assemble`; `PROMPTS(assembled)` keeps its whole text. Streaming adapters
  record each message before tools. The run's `overrides` apply to its
  catalog before the model sees it, so the model gets each tool's
  resolved schema; an invalid override keeps the run from opening. With
  `[policy] tool_output_bytes`, the output of each call the model makes,
  directly or through `tools.*`, reaches it cut to that many bytes, while
  the recorded call keeps it whole. After
  each call of the model, the runs the actions of the call ask for are
  due at once, while this run goes on; the `end` action instead stops
  the model and closes the run before its action or hook continuations,
  and the reaction runs of calling hooks are due once the run closes. When the model of a run on a work stops by itself
  and the work is still open, the work gets another run with `via` =
  `retry`, until the latest runs of the work without `end` exceed
  `max_retries`; then the harness breaks a work that has a parent with a
  comment saying so, and for a root work opens a request to the human,
  with that sentence as its reason, the options `retry` and `cancel`, and
  an inbox entry naming the request. A run opened for a named agent is
  not retried. A cancelled work does not open runs, and a work's own run
  (no named agent) does not open once its work is no longer open.
  """

  alias Omunculus.{Ceiling, Config, Cycle, Harness, Mcp, Project, Prompt, Secrets, Store}
  alias Omunculus.Execution.{Limiter, Policy}
  alias Omunculus.Tool.{Catalog, Overrides}
  alias Omunculus.Tools.Out

  @spec recover(Project.t()) :: :ok | {:error, term}
  def recover(project) do
    with {:ok, runs} <- Store.open_runs(project.conn),
         {:ok, config} <- Config.load(project.config_path) do
      Enum.reduce_while(runs, :ok, fn run, :ok ->
        case recover_one(project, config, run) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp recover_one(project, config, run) do
    with {:ok, _model} <-
           Store.record_model(project.conn, run.id, "Run interrupted by server restart."),
         {:ok, closed} <- Store.close_run(project.conn, run.id),
         :ok <- Harness.follow_up(project, [closed]),
         {:ok, work} <- Store.view(project.conn, "work", run.work_id) do
      unreported(project, %{run: run, config: config, execution: nil}, work, true)
    end
  end

  @spec open(
          Project.t(),
          %{
            prompt_id: String.t() | nil,
            work_id: String.t() | nil,
            request_id: String.t() | nil,
            via: String.t() | nil,
            agent: String.t() | nil
          }
        ) :: {:ok, map} | {:error, term}
  def open(project, opening) do
    Cycle.run(project, opening, &admitted(&1, opening))
  end

  defp admitted(project, opening) do
    with {:ok, config} <- Config.load(project.config_path),
         {:ok, global_lease} <- acquire_global(project.global_limits) do
      local_limits = Map.put(config.execution, :scope, {:project, config.store.path})

      try do
        with {:ok, lease} <- Limiter.acquire(local_limits, self(), :run) do
          try do
            start(project, config, opening)
          after
            Limiter.release(local_limits, lease, :run)
          end
        end
      after
        if global_lease, do: Limiter.release(project.global_limits, global_lease, :run)
      end
    end
  end

  defp acquire_global(nil), do: {:ok, nil}
  defp acquire_global(limits), do: Limiter.acquire(limits, self(), :run)

  defp start(
         project,
         config,
         %{
           prompt_id: message_prompt_id,
           work_id: work_id,
           request_id: request_id,
           via: via,
           agent: agent
         } = opening
       ) do
    with {:ok, work} <- fetch_work(project.conn, work_id),
         {:ok, config} <-
           Config.for_workspace(config, Config.effective_workspace(config, work)),
         {:ok, {name, text, depth, stage}} <- resolve_agent(config, project.conn, work, agent),
         {:ok, model} <- Config.model_fun(config, name),
         {:ok, message} <- fetch_prompt(project.conn, message_prompt_id),
         {:ok, grants} <- Store.grants(project.conn, work),
         workspace = Harness.workspace_context(config, work),
         context = %{
           agent: name,
           depth: depth,
           grants: grants,
           stage: stage,
           workspace: workspace.layer
         },
         local_catalog = Catalog.discover(config.tools),
         discovery_snapshot =
           Ceiling.mount(
             config,
             Map.put(context, :groups, Catalog.groups(local_catalog)),
             Map.keys(local_catalog) ++ config.execution.resources
           ),
         mcp_roots = Mcp.implementation_roots(config.mcp),
         {:ok, discovery} <-
           Policy.discovery(config, discovery_snapshot, workspace, project.dir, mcp_roots),
         catalog =
           Catalog.discover(
             config.tools,
             config.mcp,
             discovery,
             &Secrets.resolve(config, &1.secrets)
           ),
         snapshot =
           Ceiling.mount(
             config,
             Map.put(context, :groups, Catalog.groups(catalog)),
             Map.keys(catalog) ++ config.execution.resources
           ),
         {:ok, catalog} <- Overrides.apply(catalog, snapshot.overrides),
         model_catalog = Catalog.with_trigger(catalog, "model"),
         names = effective_names(snapshot, model_catalog),
         tools = effective_tools(names, model_catalog),
         {:ok, execution} <-
           Policy.build(
             config,
             snapshot,
             workspace,
             project.dir,
             names,
             Catalog.implementation_roots(catalog) ++ mcp_roots
           ),
         {:ok, assemble_name} <- assemble_tool(config, name),
         {:ok, run} <-
           Store.begin_run(project.conn, %{
             prompt_id: message_prompt_id,
             agent: name,
             depth: depth,
             ceiling: snapshot,
             execution: Policy.serializable(execution),
             work_id: work_id,
             conversation_id:
               (work && work.conversation_id) || (message && message.conversation_id) ||
                 Map.get(opening, :conversation_id),
             origin_issuer: (message && message.actor_issuer) || Map.get(opening, :origin_issuer),
             origin_subject:
               (message && message.actor_subject) || Map.get(opening, :origin_subject),
             own: is_nil(agent),
             via: via,
             request_id: request_id,
             inbox_id: Map.get(opening, :inbox_id),
             cause_id: Map.get(opening, :cause_id),
             tools: names
           }),
         {:ok, run, assembled} <-
           invoke_assemble(
             project,
             run,
             assemble_name,
             assemble_args(config, text, Map.get(opening, :inbox_id)),
             message_prompt_id,
             Map.get(opening, :inbox_id),
             execution
           ),
         cursor = :atomics.new(1, []),
         call = build_call(project, run, names, config, execution, cursor) do
      run_model(
        project,
        %{run: run, config: config, execution: execution, cursor: cursor},
        if(agent, do: nil, else: work),
        assembled,
        tools,
        call,
        model
      )
    end
  end

  defp resolve_agent(config, conn, work, agent) when not is_nil(agent) do
    case Map.fetch(config.agents, agent) do
      {:ok, agent_config} ->
        depth = if work, do: Store.work_depth(conn, work), else: agent_config.depth

        with {:ok, steps} <- workflow_steps(config, depth),
             :ok <- workflow_agent(agent, agent_config, steps),
             {:ok, step} <- step_for(steps, work && work.stage) do
          {:ok, {agent, agent_config.text, agent_config.depth, step && step.ceiling}}
        end

      :error ->
        {:error, {:no_agent, agent}}
    end
  end

  defp resolve_agent(config, _conn, nil, nil) do
    with {:ok, {name, agent}} <- Config.agent_at_depth(config, 0) do
      {:ok, {name, agent.text, 0, nil}}
    end
  end

  defp resolve_agent(config, conn, work, nil) do
    depth = Store.work_depth(conn, work)

    with {:ok, steps} <- workflow_steps(config, depth),
         {:ok, step} <- step_for(steps, work.stage) do
      case step do
        nil -> assignee_agent(config, work.assignee, depth)
        step -> {:ok, {step.agent, agent_text(config, step.agent), depth, step.ceiling}}
      end
    end
  end

  defp assignee_agent(config, name, depth) do
    case Map.fetch(config.agents, name) do
      {:ok, agent} -> {:ok, {name, agent.text, depth, nil}}
      :error -> {:error, {:no_agent, name}}
    end
  end

  defp workflow_agent(name, %{workflow_only: true}, nil), do: {:error, {:workflow_off, name}}
  defp workflow_agent(_name, _agent, _steps), do: :ok

  defp workflow_steps(config, depth) do
    case Config.workflow_for(config, depth) do
      {:ok, steps} -> {:ok, steps}
      :off -> {:ok, nil}
    end
  end

  defp step_for(nil, _stage), do: {:ok, nil}
  defp step_for(_steps, nil), do: {:ok, nil}

  defp step_for(steps, stage) do
    case Config.step_at(steps, stage) do
      {:ok, step} -> {:ok, step}
      {:error, :off_sequence} -> {:error, {:off_sequence, stage}}
    end
  end

  defp agent_text(config, name), do: config.agents |> Map.fetch!(name) |> Map.fetch!(:text)

  defp fetch_prompt(_conn, nil), do: {:ok, nil}

  defp fetch_prompt(conn, id) do
    case Store.view(conn, "prompt", id) do
      {:ok, nil} -> {:error, {:no_prompt, id}}
      {:ok, prompt} -> {:ok, prompt}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_work(_conn, nil), do: {:ok, nil}

  defp fetch_work(conn, work_id) do
    case Store.view(conn, "work", work_id) do
      {:ok, nil} -> {:error, {:no_work, work_id}}
      {:ok, work} -> {:ok, work}
      {:error, _reason} = error -> error
    end
  end

  defp assemble_tool(config, agent_name) do
    agent = Map.fetch!(config.agents, agent_name)

    case Map.get(agent, :assemble) || config.assemble do
      nil -> {:error, {:assemble, :missing}}
      name -> {:ok, name}
    end
  end

  defp assemble_args(config, text, inbox_id) do
    [{"inbox_id", inbox_id}, {"last_run_output_bytes", config.last_run_output_bytes}]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put("text", text)
  end

  defp invoke_assemble(project, run, name, args, prompt_id, inbox_id, execution) do
    ctx = %{
      trigger: "harness",
      run_id: run.id,
      author: "agent",
      agent: run.agent,
      execution: execution,
      prompt_id: prompt_id,
      request_id: run.request_id,
      inbox_id: inbox_id
    }

    case Harness.dispatch(project, name, args, ctx) do
      {:ok, out, _events} ->
        prompt = %Prompt{instructions: out.instructions, context: out.output}

        with :ok <- assembled_output(out.ok, Prompt.text(prompt)),
             {:ok, run} <- Store.attach_assembled(project.conn, run.id, Prompt.text(prompt)) do
          {:ok, run, prompt}
        else
          error -> fail_run(project, run, error)
        end

      {:error, _reason} = error ->
        fail_run(project, run, error)
    end
  end

  defp assembled_output(true, text) when text != "", do: :ok
  defp assembled_output(_ok, _text), do: {:error, {:assemble, :empty}}

  defp fail_run(project, run, reason) do
    _ = Store.close_run(project.conn, run.id)
    reason
  end

  defp effective_names(snapshot, catalog) do
    snapshot.have |> Enum.filter(&Map.has_key?(catalog, &1)) |> Enum.sort()
  end

  defp effective_tools(names, catalog) do
    Enum.map(names, fn name ->
      manifest = Map.fetch!(catalog, name)
      %{name: manifest.name, description: manifest.description, parameters: manifest.parameters}
    end)
  end

  defp build_call(project, run, names, config, execution, cursor) do
    allowed = MapSet.new(names)

    fn name, args ->
      if MapSet.member?(allowed, name) do
        ctx = %{
          trigger: "model",
          run_id: run.id,
          author: "agent",
          agent: run.agent,
          execution: execution
        }

        result = Harness.dispatch(project, name, args, ctx)
        # An action may have committed even when a hook after it failed.
        follow_call(project, run, cursor)

        case result do
          {:ok, out, _events} -> {:ok, Out.cut(out.output, config.tool_output_bytes)}
          {:error, _reason} = error -> error
        end
      else
        {:error, {:not_allowed, name}}
      end
    end
  end

  # The run's events since the last call: with `end` among them the run
  # stops; otherwise the runs their actions ask for open now, while this
  # run goes on. `cursor` holds the sequence of the last event opened.
  defp follow_call(project, run, cursor) do
    seen = :atomics.get(cursor, 1)
    events = unfollowed(project, run, seen)

    cond do
      Enum.any?(events, &Harness.ending_event?/1) ->
        throw({:run_ended, run.id})

      events == [] ->
        :ok

      :atomics.compare_exchange(cursor, 1, seen, List.last(events).sequence) != :ok ->
        follow_call(project, run, cursor)

      true ->
        case Harness.open_due(project, events) do
          :ok -> :ok
          {:error, reason} -> throw({:follow_up_failed, run.id, reason})
        end
    end
  end

  defp unfollowed(project, run, seen),
    do: project |> split_followed(run, seen) |> elem(1)

  defp split_followed(project, run, seen) do
    {:ok, events} = Store.replay(project.conn, {:run, run.id})
    Enum.split_with(events, &(&1.sequence <= seen))
  end

  defp record_model(project, run, execution, text) do
    body = if is_binary(text), do: text, else: Jason.encode!(text)

    with {:ok, event} <- Store.record_model(project.conn, run.id, body),
         {:ok, _hooks} <- Harness.react(project, [event], [], execution),
         do: :ok
  end

  defp publish_delta(project, run, text) do
    Store.publish(
      project.conn,
      {:delta,
       %{
         run_id: run.id,
         work_id: run.work_id,
         conversation_id: run.conversation_id,
         text: text
       }}
    )
  end

  defp close_run(project, run, execution) do
    with {:ok, event} <- Store.close_run(project.conn, run.id),
         {:ok, _hooks} <- Harness.react(project, [event], [], execution),
         do: :ok
  end

  defp run_model(project, state, work, assembled, tools, call, model) do
    %{run: run, execution: execution} = state
    run_id = run.id

    result =
      try do
        {:ok, events} = Store.replay(project.conn, {:run, run.id})
        start = Enum.filter(events, &(&1.type == "start-run"))

        with {:ok, _hooks} <- Harness.react(project, start, [], execution) do
          model.(
            assembled,
            tools,
            call,
            &record_model(project, run, execution, &1),
            &publish_delta(project, run, &1),
            execution
          )
        end
      rescue
        exception -> {:error, {:model_crashed, exception}}
      catch
        :throw, {:run_ended, ^run_id} -> :ended
        :throw, {:follow_up_failed, ^run_id, reason} -> {:error, reason}
        kind, reason -> {:error, {:model_crashed, {kind, reason}}}
      end

    with :ok <- close_run(project, run, execution) do
      case result do
        {:ok, _text} ->
          follow_up(project, state, work, true)

        :ended ->
          follow_up(project, state, work, false)

        {:error, _reason} = error ->
          with {:ok, _} <- follow_up(project, state, work, false),
               do: error
      end
    end
  end

  defp follow_up(project, state, work, stopped?) do
    {opened, events} = split_followed(project, state.run, :atomics.get(state.cursor, 1))

    with :ok <- Harness.follow_up(project, events, opened),
         :ok <- unreported(project, state, work, stopped?) do
      {:ok, state.run}
    end
  end

  # A run on a work whose model stopped by itself leaves the work open: the
  # store decides, in one transaction, whether the work gets another run
  # or, past max_retries, a break (a child) or a request (a root).
  defp unreported(_project, _state, nil, _stopped?), do: :ok
  defp unreported(_project, _state, _work, false), do: :ok

  defp unreported(project, state, work, true) do
    case Store.unreported(
           project.conn,
           state.run,
           state.config.max_retries,
           &Out.unreported/1,
           &Out.request_inbox/3
         ) do
      {:ok, :retry} ->
        Cycle.open(project, %{
          work_id: work.id,
          via: "retry",
          origin_issuer: state.run.origin_issuer,
          origin_subject: state.run.origin_subject
        })

      {:ok, {:stopped, events}} ->
        with {:ok, _hooks} <- Harness.react(project, events, [], state.execution) do
          Harness.follow_up(project, events)
        end

      {:ok, :none} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
