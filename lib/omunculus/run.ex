defmodule Omunculus.Run do
  @moduledoc """
  Opens a run with freshly assembled context and permissions. A named
  reaction agent still obeys the work's stage and workflow-only flags.
  Three-argument scripted models return one final message; streaming
  adapters accept a fourth callback and record each message before tools.
  Terminal actions close the run before its action or hook continuations.
  """

  alias Omunculus.{Ceiling, Config, Harness, Project, Store}
  alias Omunculus.Tool.{Catalog, Manifest}

  @ending_events ~w(request deny grant continue break delegate)

  @spec open(
          Project.t(),
          %{
            prompt_id: String.t() | nil,
            work_id: String.t() | nil,
            request_id: String.t() | nil,
            via: String.t() | nil,
            agent: String.t() | nil
          },
          (String.t(), [map], fun -> {:ok, String.t()} | {:error, term})
        ) :: {:ok, map} | {:error, term}
  def open(
        project,
        %{
          prompt_id: message_prompt_id,
          work_id: work_id,
          request_id: request_id,
          via: via,
          agent: agent
        } = opening,
        model
      ) do
    with {:ok, config} <- Config.load(project.dir),
         {:ok, work} <- fetch_work(project.conn, work_id),
         {:ok, {name, text, depth, stage}} <- resolve_agent(config, project.conn, work, agent),
         {:ok, message} <- fetch_prompt(project.conn, message_prompt_id),
         {:ok, comment} <- fetch_last_comment(project.conn, work_id),
         {:ok, inbox_notifications} <-
           fetch_inbox(project.conn, work_id, Map.get(opening, :inbox_id)),
         {:ok, grants} <- Store.grants(project.conn, work),
         {:ok, request_section} <- fetch_request_section(project.conn, request_id),
         catalog = discover_catalog(project.dir, config.mcp),
         workspace = Harness.workspace_context(config, work),
         snapshot =
           Ceiling.mount(
             config,
             %{
               agent: name,
               depth: depth,
               grants: grants,
               stage: stage,
               workspace: workspace.layer,
               groups: Catalog.groups(catalog)
             },
             Map.keys(catalog)
           ),
         names = effective_names(snapshot, catalog),
         tools = effective_tools(names, catalog),
         assembled =
           assemble(
             text,
             message,
             work,
             comment,
             inbox_notifications,
             request_section,
             names,
             catalog
           ),
         {:ok, run} <-
           Store.open_run(project.conn, %{
             prompt_id: message_prompt_id,
             agent: name,
             depth: depth,
             ceiling: snapshot,
             assembled: assembled,
             work_id: work_id,
             via: via,
             request_id: request_id,
             inbox_id: Map.get(opening, :inbox_id),
             tools: names
           }),
         call = build_call(project, run, names) do
      run_model(
        project,
        run,
        config,
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

  defp fetch_last_comment(_conn, nil), do: {:ok, nil}

  defp fetch_last_comment(conn, work_id) do
    case Store.view(conn, "comments.work", work_id) do
      {:ok, comments} -> {:ok, List.last(comments)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_inbox(conn, _work_id, inbox_id) when not is_nil(inbox_id) do
    with {:ok, comments} <- Store.view(conn, "comments.inbox", inbox_id),
         do: {:ok, %{id: inbox_id, comments: comments}}
  end

  defp fetch_inbox(_conn, nil, nil), do: {:ok, []}
  defp fetch_inbox(conn, work_id, nil), do: Store.view(conn, "inbox.work", work_id)

  defp fetch_request_section(_conn, nil), do: {:ok, []}

  defp fetch_request_section(conn, request_id) do
    with {:ok, request} <- fetch_request(conn, request_id),
         {:ok, comments} <- Store.view(conn, "comments.request", request_id) do
      {:ok, request_section(request, comments)}
    end
  end

  defp fetch_request(conn, id) do
    case Store.view(conn, "request", id) do
      {:ok, nil} -> {:error, {:no_request, id}}
      {:ok, request} -> {:ok, request}
      {:error, _reason} = error -> error
    end
  end

  defp request_section(request, comments) do
    ask = Jason.decode!(request.ask)
    header = "#{request.id}: #{ask["kind"]} #{ask["name"]} pedido por #{request.agent}"
    ["## Request\n" <> Enum.join([header | Enum.map(comments, & &1.body)], "\n")]
  end

  defp discover_catalog(dir, servers) do
    dir |> Catalog.roots() |> Catalog.discover(servers) |> Catalog.with_trigger("model")
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

  @searchable_groups ~w(store sequence catalog)

  defp assemble(
         text,
         message,
         work,
         comment,
         inbox_notifications,
         request_section,
         names,
         catalog
       ) do
    sections =
      [String.trim(text)] ++
        message_section(message) ++
        work_section(work) ++
        comment_section(comment) ++
        inbox_section(inbox_notifications) ++
        request_section ++
        [tools_section(names, catalog)]

    Enum.join(sections, "\n\n")
  end

  defp tools_section(names, catalog) do
    lines =
      if "tool_search" in names and length(names) > 12 do
        subset_lines(names, catalog)
      else
        Enum.map(names, &Manifest.card(Map.fetch!(catalog, &1)))
      end

    "## Tools\nAs tools estão em `tools.*`.\n" <> Enum.join(lines, "\n")
  end

  defp subset_lines(names, catalog) do
    {shown, omitted} = Enum.split_with(names, &searchable?(Map.fetch!(catalog, &1)))
    cards = Enum.map(shown, &Manifest.card(Map.fetch!(catalog, &1)))
    cards ++ ["Mais #{length(omitted)} tools: procure com tool_search."]
  end

  defp searchable?(%Manifest{groups: groups}), do: Enum.any?(@searchable_groups, &(&1 in groups))

  defp message_section(nil), do: []
  defp message_section(message), do: ["## Message\n#{message.body}"]

  defp work_section(nil), do: []
  defp work_section(work), do: ["## Work\n#{work.title}"]

  defp comment_section(nil), do: []
  defp comment_section(comment), do: ["## Last comment\n#{comment.body}"]

  defp inbox_section(%{id: id, comments: comments}),
    do: ["## Inbox\n#{id}\n" <> Enum.map_join(comments, "\n", & &1.body)]

  defp inbox_section([]), do: []

  defp inbox_section(notifications),
    do: ["## Inbox\n" <> Enum.map_join(notifications, "\n", & &1.body)]

  defp build_call(project, run, names) do
    allowed = MapSet.new(names)

    fn name, args ->
      if MapSet.member?(allowed, name) do
        ctx = %{trigger: "model", run_id: run.id, author: "agent", agent: run.agent}

        case Harness.dispatch(project, name, args, ctx) do
          {:ok, out, events} ->
            if Enum.any?(events, &ending_event?/1) do
              throw({:run_ended, run.id})
            end

            {:ok, out.output}

          {:error, _reason} = error ->
            # An action may already have committed before a hook failed.
            {:ok, events} = Store.replay(project.conn, {:run, run.id})
            if Enum.any?(events, &ending_event?/1), do: throw({:run_ended, run.id})
            error
        end
      else
        {:error, {:not_allowed, name}}
      end
    end
  end

  defp ending_event?(%{type: "work", body: body}), do: Jason.decode!(body)["start"] == true
  defp ending_event?(event), do: event.type in @ending_events

  defp record_model(project, run, text) do
    body = if is_binary(text), do: text, else: Jason.encode!(text)

    with {:ok, event} <- Store.record_model(project.conn, run.id, body),
         {:ok, _hooks} <- Harness.react(project, [event]),
         do: :ok
  end

  defp close_run(project, run) do
    with {:ok, event} <- Store.close_run(project.conn, run.id),
         {:ok, _hooks} <- Harness.react(project, [event]),
         do: :ok
  end

  defp run_model(project, run, config, work, assembled, tools, call, model) do
    run_id = run.id

    result =
      try do
        {:ok, events} = Store.replay(project.conn, {:run, run.id})

        with {:ok, _hooks} <- Harness.react(project, events) do
          if is_function(model, 4) do
            model.(assembled, tools, call, &record_model(project, run, &1))
          else
            with {:ok, text} <- model.(assembled, tools, call),
                 :ok <- record_model(project, run, text),
                 do: {:ok, text}
          end
        end
      rescue
        exception -> {:error, {:model_crashed, exception}}
      catch
        :throw, {:run_ended, ^run_id} -> :ended
        kind, reason -> {:error, {:model_crashed, {kind, reason}}}
      end

    with :ok <- close_run(project, run) do
      case result do
        {:ok, _text} ->
          finish_and_follow_up(project, run, config, work, model, true)

        :ended ->
          finish_and_follow_up(project, run, config, work, model, false)

        {:error, _reason} = error ->
          with {:ok, _} <- finish_and_follow_up(project, run, config, work, model, false),
               do: error
      end
    end
  end

  defp finish_and_follow_up(project, run, config, work, model, ended_normally?) do
    with :ok <- maybe_finish_work(project, config, work, run.id, ended_normally?),
         {:ok, events} <- Store.replay(project.conn, {:run, run.id}),
         :ok <- Harness.follow_up(project, events, model) do
      {:ok, run}
    end
  end

  defp maybe_finish_work(_conn, _config, nil, _run_id, _ended_normally?), do: :ok
  defp maybe_finish_work(_conn, _config, %{parent_id: nil}, _run_id, _ended_normally?), do: :ok
  defp maybe_finish_work(_conn, _config, _work, _run_id, false), do: :ok

  defp maybe_finish_work(project, config, work, run_id, true) do
    if Config.workflow_for(config, Store.work_depth(project.conn, work)) == :off do
      with {:ok, event} <- Store.finish_work(project.conn, work.id, run_id),
           {:ok, _hooks} <- Harness.react(project, [event]),
           do: :ok
    else
      :ok
    end
  end
end
