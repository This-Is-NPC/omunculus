defmodule Omunculus.Run do
  @moduledoc """
  Opens and drives one run, start to end (spec §3.2, §3.3, §3.4, §3.5).
  Resolves who runs it: depth 0 with no work; the workflow step at the
  work's stage when one applies; otherwise the plain depth agent — unless
  the opening names an `agent` (a hook reacting with a run, spec §9.6),
  in which case that named agent runs regardless of work or stage.
  Remounts the ceiling from the project config, the run's workspace layer
  (`Harness.workspace_context/2`, spec §9.1), and the work's own and
  ancestors' grants on every opening — it never reuses a previous run's
  ceiling. Assembles the prompt from the agent text, the message of this
  opening (when there is one), the work's title and last comment when the
  run is on a work, the work's unread notifications, the request and its
  comments when the run answers one, and the have tools' cards — when
  `tool_search` is among them and there are more than 12, only the cards
  of the `store`, `sequence` or `catalog` groups, plus a count of the
  rest, since the model can search for the others — lets the model call
  tools through the harness, and closes the run when the model is done or
  a call it made ended the run with a decision. Once closed, a work whose
  sequence is off
  and that has a parent is finished, and the replay of this run is handed
  to `Omunculus.Harness.follow_up/3` so the next run, if any, opens
  before this one returns. Nobody waits.
  """

  alias Omunculus.{Ceiling, Config, Harness, Project, Store}
  alias Omunculus.Tool.{Catalog, Manifest}

  @ending_events ~w(request deny continue break delegate)

  @spec open(
          Project.t(),
          %{
            prompt_id: String.t() | nil,
            work_id: String.t() | nil,
            request_id: String.t() | nil,
            via: String.t() | nil,
            agent: String.t() | nil
          },
          (String.t(), fun -> {:ok, String.t()} | {:error, term})
        ) :: {:ok, map} | {:error, term}
  def open(
        project,
        %{
          prompt_id: message_prompt_id,
          work_id: work_id,
          request_id: request_id,
          via: via,
          agent: agent
        },
        model
      ) do
    with {:ok, config} <- Config.load(project.dir),
         {:ok, work} <- fetch_work(project.conn, work_id),
         {:ok, {name, text, depth, stage}} <- resolve_agent(config, project.conn, work, agent),
         {:ok, message} <- fetch_prompt(project.conn, message_prompt_id),
         {:ok, comment} <- fetch_last_comment(project.conn, work_id),
         {:ok, inbox_notifications} <- fetch_inbox(project.conn, work_id),
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
             request_id: request_id
           }),
         call = build_call(project, run, names) do
      run_model(project, run, config, work, assembled, call, model)
    end
  end

  defp resolve_agent(config, _conn, _work, agent) when not is_nil(agent) do
    case Map.fetch(config.agents, agent) do
      {:ok, agent_config} -> {:ok, {agent, agent_config.text, agent_config.depth, nil}}
      :error -> {:error, {:no_agent, agent}}
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

  defp fetch_inbox(_conn, nil), do: {:ok, []}

  defp fetch_inbox(conn, work_id), do: Store.view(conn, "inbox.work", work_id)

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
    header = "#{ask["kind"]} #{ask["name"]} pedido por #{request.agent}"
    ["## Request\n" <> Enum.join([header | Enum.map(comments, & &1.body)], "\n")]
  end

  defp discover_catalog(dir, servers) do
    dir |> Catalog.roots() |> Catalog.discover(servers) |> Catalog.with_trigger("model")
  end

  defp effective_names(snapshot, catalog) do
    snapshot.have |> Enum.filter(&Map.has_key?(catalog, &1)) |> Enum.sort()
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
            if Enum.any?(events, &(&1.type in @ending_events)) do
              throw({:run_ended, run.id})
            end

            {:ok, out.output}

          {:error, _reason} = error ->
            error
        end
      else
        {:error, {:not_allowed, name}}
      end
    end
  end

  defp run_model(project, run, config, work, assembled, call, model) do
    run_id = run.id

    result =
      try do
        model.(assembled, call)
      catch
        :throw, {:run_ended, ^run_id} -> :ended
      end

    case result do
      {:ok, text} ->
        with {:ok, _event} <- Store.record_model(project.conn, run.id, text),
             {:ok, _event} <- Store.close_run(project.conn, run.id) do
          finish_and_follow_up(project, run, config, work, model, true)
        end

      :ended ->
        with {:ok, _event} <- Store.close_run(project.conn, run.id) do
          finish_and_follow_up(project, run, config, work, model, false)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_and_follow_up(project, run, config, work, model, ended_normally?) do
    with :ok <- maybe_finish_work(project.conn, config, work, run.id, ended_normally?),
         {:ok, events} <- Store.replay(project.conn, {:run, run.id}),
         :ok <- Harness.follow_up(project, events, model) do
      {:ok, run}
    end
  end

  defp maybe_finish_work(_conn, _config, nil, _run_id, _ended_normally?), do: :ok
  defp maybe_finish_work(_conn, _config, %{parent_id: nil}, _run_id, _ended_normally?), do: :ok
  defp maybe_finish_work(_conn, _config, _work, _run_id, false), do: :ok

  defp maybe_finish_work(conn, config, work, run_id, true) do
    if Config.workflow_for(config, Store.work_depth(conn, work)) == :off do
      with {:ok, _event} <- Store.finish_work(conn, work.id, run_id), do: :ok
    else
      :ok
    end
  end
end
