defmodule Omunculus.Harness do
  @moduledoc """
  Discovers and dispatches tool names through the shared contract. Hydrates
  declared views, commits calls and emits atomically, then reacts to their
  events. Run lifecycle events use the same `react/2` path.

  Only actions schedule protocol runs. Hooks can emit notifications and
  comments, or name an agent for a separate reaction run; their programs
  cannot sequence work directly. `follow_up/3` opens action runs before
  agent reactions, preserving the originating tool or hook in `via`.
  """

  alias Omunculus.{Config, Project, Run, Store}
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}

  @spec manifest(Project.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, {:unknown_tool, String.t()}}
  def manifest(%Project{dir: dir}, name) do
    with {:ok, config} <- Config.load(dir) do
      dir |> Catalog.roots() |> Catalog.discover(config.mcp) |> fetch_manifest(name)
    end
  end

  @spec workspace_context(Config.t(), map | nil) :: %{
          name: String.t() | nil,
          root: String.t() | nil,
          layer: Omunculus.Config.Layer.t() | nil
        }
  def workspace_context(config, work) do
    name = Config.effective_workspace(config, work)

    %{
      name: name,
      root: Config.workspace_root(config, name),
      layer: Config.workspace_ceiling(config, name)
    }
  end

  @spec dispatch(Project.t(), String.t(), map, map) :: {:ok, map, [map]} | {:error, term}
  def dispatch(project, name, args, ctx) do
    with {:ok, config} <- Config.load(project.dir),
         catalog = project.dir |> Catalog.roots() |> Catalog.discover(config.mcp),
         {:ok, manifest} <- fetch_manifest(catalog, name),
         :ok <- check_trigger(manifest, name, ctx.trigger),
         {:ok, run} <- resolve_run(project, ctx.run_id),
         work_id = run_work_id(run),
         {:ok, work} <- fetch_work(project, work_id),
         workspace = workspace_context(config, work),
         views = %{
           catalog: catalog_view(run, catalog),
           workspaces: workspaces_view(config, workspace.name),
           request_id: run && run.request_id,
           inbox_id: run_inbox_id(project, run),
           paths: path_permissions(project, run, workspace)
         },
         {:ok, out, events} <-
           call(project, manifest, args, work_id, ctx, config, catalog, views, workspace),
         {:ok, hook_events} <-
           react(project, events) do
      {:ok, augment(out, events), events ++ hook_events}
    end
  end

  @doc "Dispatches reactions to committed events, including the run lifecycle."
  def react(project, events, active \\ []) do
    with {:ok, config} <- Config.load(project.dir) do
      catalog = project.dir |> Catalog.roots() |> Catalog.discover(config.mcp)

      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
        with {:ok, run} <- resolve_run(project, event.run_id),
             {:ok, work} <- fetch_work(project, event.work_id) do
          workspace = workspace_context(config, work)

          ctx = %{
            run_id: event.run_id,
            author: if(run, do: "agent", else: "human"),
            agent: run && run.agent,
            request_id: event.request_id,
            inbox_id: event.inbox_id,
            via: run && run.via
          }

          views = %{
            catalog: catalog_view(run, catalog),
            workspaces: workspaces_view(config, workspace.name),
            request_id: event.request_id,
            inbox_id: event.inbox_id,
            paths: path_permissions(project, run, workspace)
          }

          case run_hooks_for(
                 project,
                 catalog,
                 event,
                 event.work_id,
                 ctx,
                 config,
                 views,
                 workspace,
                 active
               ) do
            {:ok, result} -> {:cont, {:ok, acc ++ result}}
            error -> {:halt, error}
          end
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp start_event(_project, nil), do: nil

  defp start_event(project, run) do
    {:ok, event} = Store.view(project.conn, "event", run.event_id)
    event
  end

  defp run_inbox_id(project, run) do
    event = start_event(project, run)
    event && event.inbox_id
  end

  defp path_permissions(project, run, workspace) do
    case start_event(project, run) do
      nil ->
        %{}

      event ->
        Omunculus.Ceiling.paths(
          Jason.decode!(event.body)["ceiling"],
          workspace.root || project.dir
        )
    end
  end

  @spec follow_up(Project.t(), [map], (String.t(), fun -> {:ok, String.t()} | {:error, term})) ::
          :ok | {:error, term}
  def follow_up(project, events, model) do
    with {:ok, config} <- Config.load(project.dir),
         catalog = project.dir |> Catalog.roots() |> Catalog.discover(config.mcp),
         {:ok, _via} <- walk(project, catalog, events, model, :actions),
         {:ok, _via} <- walk(project, catalog, events, model, :hooks) do
      :ok
    end
  end

  defp walk(project, catalog, events, model, phase) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, via} ->
      case advance(project, catalog, event, via, model, phase) do
        {:ok, _via} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_manifest(catalog, name) do
    case Map.fetch(catalog, name) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  defp check_trigger(manifest, name, trigger) do
    if Manifest.triggered_by?(manifest, trigger),
      do: :ok,
      else: {:error, {:not_triggered, name, trigger}}
  end

  defp resolve_run(_project, nil), do: {:ok, nil}

  defp resolve_run(project, run_id) do
    case Store.view(project.conn, "run", run_id) do
      {:ok, nil} -> {:error, {:no_run, run_id}}
      {:ok, run} -> {:ok, run}
      {:error, _reason} = error -> error
    end
  end

  defp run_work_id(nil), do: nil
  defp run_work_id(run), do: run.work_id

  defp fetch_work(_project, nil), do: {:ok, nil}

  defp fetch_work(project, work_id) do
    Store.view(project.conn, "work", work_id)
  end

  defp workspaces_view(config, current) do
    config.workspaces
    |> Enum.sort_by(fn {name, _workspace} -> name end)
    |> Enum.map(fn {name, workspace} ->
      %{name: name, root: workspace.root, current: name == current}
    end)
  end

  defp catalog_view(nil, _catalog), do: []

  defp catalog_view(%{tools: tools}, catalog) do
    model_catalog = Catalog.with_trigger(catalog, "model")
    names = if tools, do: Jason.decode!(tools), else: []

    names
    |> Enum.filter(&Map.has_key?(model_catalog, &1))
    |> Enum.sort()
    |> Enum.map(&catalog_card(Map.fetch!(model_catalog, &1)))
  end

  defp catalog_card(%Manifest{name: name, description: description, tags: tags}),
    do: %{name: name, description: description, tags: tags}

  defp store_ctx(ctx, work_id, config, catalog),
    do: %{
      run_id: ctx.run_id,
      work_id: work_id,
      author: ctx.author,
      agent: ctx.agent,
      config: config,
      groups: Catalog.groups(catalog),
      request_id: Map.get(ctx, :request_id),
      inbox_id: Map.get(ctx, :inbox_id)
    }

  defp hydrate_views(project, names, run_id, work_id, views) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_view_id(name, run_id, work_id, views) do
        {:error, _reason} = error -> {:halt, error}
        :skip -> {:cont, {:ok, acc}}
        :catalog -> {:cont, {:ok, Map.put(acc, "catalog", views.catalog)}}
        :workspaces -> {:cont, {:ok, Map.put(acc, "workspaces", views.workspaces)}}
        :paths -> {:cont, {:ok, Map.put(acc, "paths", views.paths)}}
        {:ok, id} -> fetch_view(project, name, id, acc)
      end
    end)
  end

  defp fetch_view(project, name, id, acc) do
    case Store.view(project.conn, name, id) do
      {:ok, result} -> {:cont, {:ok, Map.put(acc, name, result)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @work_scoped_views ~w(work comments.work inbox.work)

  defp resolve_view_id(name, _run_id, work_id, _request_id) when name in @work_scoped_views do
    if work_id, do: {:ok, work_id}, else: :skip
  end

  defp resolve_view_id("events.run", run_id, _work_id, _request_id) do
    if run_id, do: {:ok, run_id}, else: :skip
  end

  defp resolve_view_id("comments.request", _run_id, _work_id, %{request_id: request_id}) do
    if request_id, do: {:ok, request_id}, else: :skip
  end

  defp resolve_view_id("comments.inbox", _run_id, _work_id, %{inbox_id: inbox_id}) do
    if inbox_id, do: {:ok, inbox_id}, else: :skip
  end

  defp resolve_view_id("paths", _run_id, _work_id, _views), do: :paths
  defp resolve_view_id("inbox", _run_id, _work_id, _request_id), do: {:ok, nil}
  defp resolve_view_id("catalog", _run_id, _work_id, _request_id), do: :catalog
  defp resolve_view_id("workspaces", _run_id, _work_id, _request_id), do: :workspaces
  defp resolve_view_id(name, _run_id, _work_id, _request_id), do: {:error, {:unknown_view, name}}

  defp run_hooks_for(project, catalog, event, work_id, ctx, config, views, workspace, active) do
    catalog
    |> Catalog.hooks_for(event.type)
    |> Enum.reject(&(&1.name == Map.get(ctx, :via) or &1.name in active))
    |> Enum.reduce_while({:ok, []}, fn hook, {:ok, acc} ->
      case invoke_hook(project, hook, event, work_id, ctx, config, catalog, views, workspace) do
        {:ok, hook_events} ->
          case react(project, hook_events, [hook.name | active]) do
            {:ok, reactions} -> {:cont, {:ok, acc ++ hook_events ++ reactions}}
            error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp invoke_hook(project, hook, event, work_id, ctx, config, catalog, views, workspace) do
    with {:ok, _out, events} <-
           call(
             project,
             hook,
             %{"event" => stringify(event)},
             work_id,
             ctx,
             config,
             catalog,
             views,
             workspace
           ) do
      {:ok, events}
    end
  end

  defp call(project, manifest, args, work_id, ctx, config, catalog, views, workspace) do
    with {:ok, view} <- hydrate_views(project, manifest.views, ctx.run_id, work_id, views),
         input = %{
           name: manifest.name,
           args: args,
           view: view,
           run_id: ctx.run_id,
           work_id: work_id,
           workspace: workspace.name,
           roots: if(workspace.root, do: [workspace.root], else: [project.dir])
         },
         {:ok, out} <- Invoke.call(manifest, input),
         emits = if(out.ok, do: out.emit, else: []),
         record = %{name: manifest.name, args: args, ok: out.ok, output: out.output},
         :ok <- check_hook_emits(manifest, emits),
         {:ok, events} <-
           Store.record_tool(
             project.conn,
             ctx.run_id,
             record,
             emits,
             store_ctx(ctx, work_id, config, catalog)
           ) do
      {:ok, out, events}
    end
  end

  defp check_hook_emits(%{kind: "hook"}, emits) do
    case Enum.find(emits, &(&1["type"] in ~w(prompt work request reply delegate continue break))) do
      nil -> :ok
      emit -> {:error, {:hook, {:cannot_sequence, emit["type"]}}}
    end
  end

  defp check_hook_emits(_manifest, _emits), do: :ok

  defp stringify(event), do: Map.new(event, fn {key, value} -> {to_string(key), value} end)

  defp augment(%{ok: true, emit: emits} = out, events) do
    case request_emit_name(emits) do
      nil ->
        out

      name ->
        if Enum.any?(events, &(&1.type in ["request", "deny"])) do
          out
        else
          %{out | output: out.output <> "\nalready granted: #{name}"}
        end
    end
  end

  defp augment(out, _events), do: out

  defp request_emit_name(emits) do
    Enum.find_value(emits, fn
      %{"type" => "request", "body" => %{"name" => name}} -> name
      _ -> nil
    end)
  end

  defp advance(project, catalog, %{type: "tool", body: body} = event, _via, model, :hooks) do
    name = Jason.decode!(body)["name"]

    case Map.get(catalog, name) do
      %Manifest{kind: "hook", agent: agent} when not is_nil(agent) ->
        with :ok <- open_reaction_run(project, event, name, agent, model), do: {:ok, name}

      _not_a_calling_hook ->
        {:ok, name}
    end
  end

  defp advance(_project, _catalog, %{type: "tool", body: body}, _via, _model, :actions),
    do: {:ok, Jason.decode!(body)["name"]}

  defp advance(project, _catalog, %{type: "prompt"} = event, via, model, :actions) do
    with :ok <-
           open_run(
             project,
             open_params(prompt_id: event.prompt_id, work_id: event.work_id, via: via),
             model
           ),
         do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "grant"} = event, via, model, :actions) do
    with :ok <- apply_grant(project, event),
         :ok <- open_grant_run(project, event, via, model) do
      {:ok, via}
    end
  end

  defp advance(project, _catalog, %{type: "continue"} = event, via, model, :actions) do
    with :ok <- open_continue_run(project, event, via, model), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "delegate"} = event, via, model, :actions) do
    with :ok <-
           open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via), model),
         do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "request"} = event, via, model, :actions) do
    with :ok <- open_request_run(project, event, via, model), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "work"} = event, via, model, :actions) do
    with :ok <- open_finished_work_run(project, event, via, model), do: {:ok, via}
  end

  defp advance(_project, _catalog, _event, via, _model, _phase), do: {:ok, via}

  defp open_params(prompt_id: prompt_id, work_id: work_id, via: via),
    do: %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: via, agent: nil}

  defp open_reaction_run(project, event, hook_name, agent, model) do
    open_run(
      project,
      %{
        prompt_id: nil,
        work_id: event.work_id,
        request_id: event.request_id,
        inbox_id: event.inbox_id,
        via: hook_name,
        agent: agent
      },
      model
    )
  end

  defp apply_grant(project, event) do
    body = Jason.decode!(event.body)

    case body["scope"] do
      "agent" ->
        Config.grant(project.dir, {:agent, body["agent"]}, body["name"])

      "depth" ->
        Config.grant(project.dir, {:depth, body["depth"]}, body["name"])

      "stage" ->
        Config.grant(project.dir, {:stage, body["workflow"], body["stage"]}, body["name"])

      "workspace" ->
        Config.grant(project.dir, {:workspace, body["workspace"]}, body["name"])

      _ ->
        :ok
    end
  end

  defp open_grant_run(_project, %{work_id: nil}, _via, _model), do: :ok

  defp open_grant_run(project, %{work_id: work_id, request_id: request_id}, via, model) do
    open_run(
      project,
      %{prompt_id: nil, work_id: work_id, request_id: request_id, via: via, agent: nil},
      model
    )
  end

  defp open_continue_run(project, event, via, model) do
    case Jason.decode!(event.body) do
      %{"to" => to} when not is_nil(to) ->
        open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via), model)

      %{"parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(project, open_params(prompt_id: nil, work_id: parent_id, via: via), model)

      _no_next_run ->
        :ok
    end
  end

  defp open_request_run(project, event, via, model) do
    case Jason.decode!(event.body) do
      %{"arbiter" => arbiter, "arbiter_work_id" => work_id} ->
        with :ok <-
               open_run(
                 project,
                 %{
                   prompt_id: nil,
                   work_id: work_id,
                   request_id: event.request_id,
                   via: via,
                   agent: arbiter
                 },
                 model
               ),
             do: :ok

      _no_agent_arbiter ->
        :ok
    end
  end

  defp open_finished_work_run(project, event, via, model) do
    case Jason.decode!(event.body) do
      %{"start" => true} ->
        open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via), model)

      %{"state" => "done", "parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(
          project,
          %{prompt_id: nil, work_id: parent_id, request_id: nil, via: nil, agent: nil},
          model
        )

      _no_parent_to_wake ->
        :ok
    end
  end

  defp open_run(project, params, model) do
    case Run.open(project, params, model) do
      {:ok, _run} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
