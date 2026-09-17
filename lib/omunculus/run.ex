defmodule Omunculus.Run do
  @moduledoc """
  Opens a run with freshly assembled context and permissions. A named
  reaction agent still obeys the work's stage and workflow-only flags.
  The agent's `model` from config is constructed via `new/1`. The
  assembled prompt is the `output` of the tool named by
  `agents.<x>.assemble` or `[policy] assemble`. Streaming adapters
  record each message before tools. Terminal actions close the run
  before its action or hook continuations.
  """

  alias Omunculus.{Ceiling, Config, Harness, Mcp, Project, Store}
  alias Omunculus.Execution.Policy
  alias Omunculus.Tool.Catalog

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
  def open(
        project,
        %{
          prompt_id: message_prompt_id,
          work_id: work_id,
          request_id: request_id,
          via: via,
          agent: agent
        } = opening
      ) do
    with {:ok, config} <- Config.load(project.config_path),
         {:ok, work} <- fetch_work(project.conn, work_id),
         {:ok, config} <-
           Config.for_workspace(config, Config.effective_workspace(config, work)),
         {:ok, {name, text, depth, stage}} <- resolve_agent(config, project.conn, work, agent),
         {:ok, model} <- Config.model_fun(config, name),
         {:ok, _message} <- fetch_prompt(project.conn, message_prompt_id),
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
         catalog = Catalog.discover(config.tools, config.mcp, discovery),
         model_catalog = Catalog.with_trigger(catalog, "model"),
         snapshot =
           Ceiling.mount(
             config,
             Map.put(context, :groups, Catalog.groups(catalog)),
             Map.keys(catalog) ++ config.execution.resources
           ),
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
             via: via,
             request_id: request_id,
             inbox_id: Map.get(opening, :inbox_id),
             tools: names
           }),
         {:ok, run, assembled} <-
           invoke_assemble(
             project,
             run,
             assemble_name,
             text,
             message_prompt_id,
             Map.get(opening, :inbox_id),
             execution
           ),
         call = build_call(project, run, names, execution) do
      run_model(
        project,
        run,
        config,
        if(agent, do: nil, else: work),
        assembled,
        tools,
        call,
        model,
        execution
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
        nil -> agent_at_depth(config, depth)
        step -> {:ok, {step.agent, agent_text(config, step.agent), depth, step.ceiling}}
      end
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

  defp agent_at_depth(config, depth) do
    with {:ok, {name, agent}} <- Config.agent_at_depth(config, depth) do
      {:ok, {name, agent.text, depth, nil}}
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

  defp invoke_assemble(project, run, name, text, prompt_id, inbox_id, execution) do
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

    args =
      %{"text" => text}
      |> then(fn args -> if inbox_id, do: Map.put(args, "inbox_id", inbox_id), else: args end)

    case Harness.dispatch(project, name, args, ctx) do
      {:ok, out, _events} ->
        with :ok <- assembled_output(out),
             {:ok, run} <- Store.attach_assembled(project.conn, run.id, out.output) do
          {:ok, run, out.output}
        else
          error -> fail_run(project, run, error)
        end

      {:error, _reason} = error ->
        fail_run(project, run, error)
    end
  end

  defp assembled_output(%{ok: true, output: output}) when is_binary(output) and output != "",
    do: :ok

  defp assembled_output(_out), do: {:error, {:assemble, :empty}}

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

  defp build_call(project, run, names, execution) do
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

        case Harness.dispatch(project, name, args, ctx) do
          {:ok, out, events} ->
            if Enum.any?(events, &Harness.ending_event?/1) do
              throw({:run_ended, run.id})
            end

            {:ok, out.output}

          {:error, _reason} = error ->
            # An action may already have committed before a hook failed.
            {:ok, events} = Store.replay(project.conn, {:run, run.id})
            if Enum.any?(events, &Harness.ending_event?/1), do: throw({:run_ended, run.id})
            error
        end
      else
        {:error, {:not_allowed, name}}
      end
    end
  end

  defp record_model(project, run, execution, text) do
    body = if is_binary(text), do: text, else: Jason.encode!(text)

    with {:ok, event} <- Store.record_model(project.conn, run.id, body),
         {:ok, _hooks} <- Harness.react(project, [event], [], execution),
         do: :ok
  end

  defp close_run(project, run, execution) do
    with {:ok, event} <- Store.close_run(project.conn, run.id),
         {:ok, _hooks} <- Harness.react(project, [event], [], execution),
         do: :ok
  end

  defp run_model(project, run, config, work, assembled, tools, call, model, execution) do
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
            execution
          )
        end
      rescue
        exception -> {:error, {:model_crashed, exception}}
      catch
        :throw, {:run_ended, ^run_id} -> :ended
        kind, reason -> {:error, {:model_crashed, {kind, reason}}}
      end

    with :ok <- close_run(project, run, execution) do
      case result do
        {:ok, _text} ->
          finish_and_follow_up(project, run, config, work, execution, true)

        :ended ->
          finish_and_follow_up(project, run, config, work, execution, false)

        {:error, _reason} = error ->
          with {:ok, _} <-
                 finish_and_follow_up(project, run, config, work, execution, false),
               do: error
      end
    end
  end

  defp finish_and_follow_up(project, run, config, work, execution, ended_normally?) do
    with :ok <- maybe_finish_work(project, config, work, run.id, execution, ended_normally?),
         {:ok, events} <- Store.replay(project.conn, {:run, run.id}),
         :ok <- Harness.follow_up(project, events) do
      {:ok, run}
    end
  end

  defp maybe_finish_work(_conn, _config, nil, _run_id, _execution, _ended_normally?), do: :ok

  defp maybe_finish_work(
         _conn,
         _config,
         %{parent_id: nil},
         _run_id,
         _execution,
         _ended_normally?
       ),
       do: :ok

  defp maybe_finish_work(_conn, _config, _work, _run_id, _execution, false), do: :ok

  defp maybe_finish_work(project, config, work, run_id, execution, true) do
    if Config.workflow_for(config, Store.work_depth(project.conn, work)) == :off do
      with {:ok, event} <- Store.finish_work(project.conn, work.id, run_id),
           {:ok, _hooks} <- Harness.react(project, [event], [], execution),
           do: :ok
    else
      :ok
    end
  end
end
