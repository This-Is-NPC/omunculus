defmodule Omunculus.Harness do
  @moduledoc """
  Discovers and dispatches tool names through the shared contract. Hydrates
  declared views, commits calls and emits atomically, then reacts to their
  events. Run lifecycle events use the same `react/2` path.

  Hooks use the same emit path as tools. Non-terminal events still run
  hooks during the model unroll; events that end the run wait until
  `follow_up/2` has closed the run and opened the next one. `follow_up/2`
  opens action runs, then those deferred hooks, then agent reactions,
  preserving the originating tool or hook in `via`.
  """

  alias Omunculus.{Config, Project, Run, Store}
  alias Omunculus.Execution.Policy
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}
  alias Omunculus.Tools.Out

  @spec manifest(Project.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, {:unknown_tool, String.t()}}
  def manifest(%Project{config_path: path}, name) do
    with {:ok, config} <- Config.load(path),
         {:ok, config} <- Config.for_workspace(config, Config.effective_workspace(config, nil)) do
      config.tools |> Catalog.discover(config.mcp, nil) |> fetch_dispatch_manifest(name, "cli")
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

  defp resolved_config(project, work) do
    with {:ok, config} <- Config.load(project.config_path) do
      Config.for_workspace(config, Config.effective_workspace(config, work))
    end
  end

  @spec dispatch(Project.t(), String.t(), map, map) :: {:ok, map, [map]} | {:error, term}
  def dispatch(project, name, args, ctx) do
    folder_catalog = Catalog.unconfigured()

    case Map.get(folder_catalog, name) do
      %Manifest{config: false} = manifest when ctx.trigger == "cli" ->
        dispatch_without_config(project, manifest, args, ctx)

      _other ->
        dispatch_with_config(project, name, args, ctx)
    end
  end

  defp dispatch_without_config(project, manifest, args, ctx) do
    with :ok <- check_trigger(manifest, manifest.name, ctx.trigger) do
      input = %{
        name: manifest.name,
        args: args,
        view: %{},
        run_id: nil,
        work_id: nil,
        workspace: nil,
        roots: [project.dir],
        config_path: project.config_path
      }

      case Invoke.call(manifest, input) do
        {:ok, out} -> {:ok, out, []}
        {:error, _reason} = error -> error
      end
    end
  end

  defp dispatch_with_config(project, name, args, ctx) do
    with {:ok, run} <- resolve_run(project, ctx.run_id),
         work_id = run_work_id(run),
         {:ok, work} <- fetch_work(project, work_id),
         {:ok, config} <- resolved_config(project, work),
         catalog =
           Catalog.discover(config.tools, config.mcp, Map.get(ctx, :execution)),
         {:ok, manifest} <- fetch_dispatch_manifest(catalog, name, ctx.trigger),
         :ok <- check_trigger(manifest, name, ctx.trigger),
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
           maybe_react(project, events, [], Map.get(ctx, :execution)) do
      {:ok, augment(out, events), events ++ hook_events}
    end
  end

  @doc "Dispatches reactions to committed events, including the run lifecycle."
  def react(project, events, active \\ [], execution \\ nil) do
    with {:ok, base} <- Config.load(project.config_path) do
      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
        with {:ok, run} <- resolve_run(project, event.run_id),
             {:ok, work} <- fetch_work(project, event.work_id),
             {:ok, config} <-
               Config.for_workspace(base, Config.effective_workspace(base, work)) do
          catalog = Catalog.discover(config.tools, config.mcp, execution)
          workspace = workspace_context(config, work)

          ctx = %{
            run_id: event.run_id,
            author: if(run, do: "agent", else: "human"),
            agent: run && run.agent,
            request_id: event.request_id,
            inbox_id: event.inbox_id,
            via: run && run.via,
            execution: execution
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

  @spec follow_up(Project.t(), [map]) :: :ok | {:error, term}
  def follow_up(project, events) do
    with {:ok, config} <- Config.load(project.config_path),
         {:ok, config} <- Config.for_workspace(config, Config.effective_workspace(config, nil)),
         catalog = Catalog.discover(config.tools, config.mcp, nil),
         {:ok, _via} <- walk(project, catalog, events, :actions),
         {:ok, _hooks} <- react(project, Enum.filter(events, &ending_event?/1), []),
         {:ok, _via} <- walk(project, catalog, events, :hooks) do
      :ok
    end
  end

  defp walk(project, catalog, events, phase) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, via} ->
      case advance(project, catalog, event, via, phase) do
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

  defp fetch_dispatch_manifest(catalog, name, "cli") do
    case fetch_manifest(catalog, name) do
      {:ok, _manifest} = ok ->
        ok

      {:error, {:unknown_tool, ^name}} ->
        case Map.fetch(Catalog.unconfigured(), name) do
          {:ok, %Manifest{config: true} = manifest} ->
            if Manifest.triggered_by?(manifest, "cli"),
              do: {:ok, manifest},
              else: {:error, {:unknown_tool, name}}

          _missing ->
            {:error, {:unknown_tool, name}}
        end
    end
  end

  defp fetch_dispatch_manifest(catalog, name, _trigger), do: fetch_manifest(catalog, name)

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
        {:cli_prompt, args} -> fetch_cli_prompt(project, name, args, acc)
        {:ok, canonical, id} -> fetch_view(project, name, canonical, id, acc)
        {:ok, id} -> fetch_view(project, name, name, id, acc)
      end
    end)
  end

  defp fetch_view(project, declared, canonical, id, acc) do
    case Store.view(project.conn, canonical, id) do
      {:ok, result} ->
        acc = Map.put(acc, declared, result)
        acc = if declared == canonical, do: acc, else: Map.put(acc, canonical, result)
        {:cont, {:ok, acc}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  @work_scoped_views ~w(work comments.work inbox.work)

  defp resolve_view_id(name, _run_id, work_id, _request_id) when name in @work_scoped_views do
    if work_id, do: {:ok, work_id}, else: :skip
  end

  defp resolve_view_id("events.run", run_id, _work_id, _request_id) do
    if run_id, do: {:ok, run_id}, else: :skip
  end

  defp resolve_view_id("events", run_id, _work_id, _views) do
    if run_id, do: {:ok, "events.run", run_id}, else: :skip
  end

  defp resolve_view_id("comments", _run_id, work_id, views) do
    cond do
      is_binary(work_id) -> {:ok, "comments.work", work_id}
      is_binary(views[:request_id]) -> {:ok, "comments.request", views.request_id}
      is_binary(views[:inbox_id]) -> {:ok, "comments.inbox", views.inbox_id}
      true -> :skip
    end
  end

  defp resolve_view_id("comments.request", _run_id, _work_id, %{request_id: request_id}) do
    if request_id, do: {:ok, request_id}, else: :skip
  end

  defp resolve_view_id("comments.inbox", _run_id, _work_id, %{inbox_id: inbox_id}) do
    if inbox_id, do: {:ok, inbox_id}, else: :skip
  end

  defp resolve_view_id("paths", _run_id, _work_id, _views), do: :paths
  defp resolve_view_id("counter", _run_id, _work_id, _views), do: {:ok, nil}
  defp resolve_view_id("inbox", _run_id, _work_id, _request_id), do: {:ok, nil}
  defp resolve_view_id("catalog", _run_id, _work_id, _request_id), do: :catalog
  defp resolve_view_id("workspaces", _run_id, _work_id, _request_id), do: :workspaces
  defp resolve_view_id("runs.last", _run_id, _work_id, _views), do: {:ok, nil}

  defp resolve_view_id("prompt", _run_id, _work_id, %{trigger: "cli"} = views),
    do: {:cli_prompt, Map.get(views, :args, %{})}

  defp resolve_view_id(name, _run_id, _work_id, _request_id), do: {:error, {:unknown_view, name}}

  defp fetch_cli_prompt(project, name, args, acc) do
    case cli_assembled_id(project, args) do
      {:ok, id} -> fetch_view(project, name, "prompt", id, acc)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp cli_assembled_id(project, args) do
    with {:ok, run} <- cli_run(project, Map.get(args, "run")),
         id when is_binary(id) and id != "" <- run.prompt_id do
      {:ok, id}
    else
      nil -> {:error, :no_assembled}
      {:error, _reason} = error -> error
    end
  end

  defp cli_run(project, id) when is_binary(id) and id != "" do
    case Store.view(project.conn, "run", id) do
      {:ok, nil} -> {:error, {:unknown_run, id}}
      other -> other
    end
  end

  defp cli_run(project, _id) do
    case Store.view(project.conn, "runs.last", nil) do
      {:ok, nil} -> {:error, :no_runs}
      other -> other
    end
  end

  defp run_hooks_for(project, catalog, event, work_id, ctx, config, views, workspace, active) do
    catalog
    |> Catalog.hooks_for(event.type)
    |> Enum.reject(&(&1.name == Map.get(ctx, :via) or &1.name in active))
    |> Enum.reduce_while({:ok, []}, fn hook, {:ok, acc} ->
      case invoke_hook(project, hook, event, work_id, ctx, config, catalog, views, workspace) do
        {:ok, hook_events} ->
          case maybe_react(project, hook_events, [hook.name | active], ctx.execution) do
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
    with {:ok, execution} <-
           execution_context(manifest, ctx, config, workspace, project.dir, catalog),
         views = Map.merge(views, %{trigger: Map.get(ctx, :trigger), args: args}),
         {:ok, view} <- hydrate_views(project, manifest.views, ctx.run_id, work_id, views),
         input = %{
           name: manifest.name,
           args: args,
           view: view,
           run_id: ctx.run_id,
           work_id: work_id,
           workspace: workspace.name,
           roots: if(workspace.root, do: [workspace.root], else: [project.dir]),
           config_path: project.config_path
         },
         {:ok, out} <- Invoke.call(manifest, input, execution),
         emits = if(out.ok, do: out.emit, else: []),
         record = %{name: manifest.name, args: args, ok: out.ok, output: out.output},
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

  @ending_events ~w(request deny grant continue break delegate)

  defp maybe_react(project, events, active, execution) do
    react(project, Enum.reject(events, &ending_event?/1), active, execution)
  end

  @spec ending_event?(map) :: boolean
  def ending_event?(%{type: "work", body: body}), do: Jason.decode!(body)["start"] == true
  def ending_event?(event), do: event.type in @ending_events

  defp execution_context(
         _manifest,
         %{execution: %Policy{} = execution},
         _config,
         _workspace,
         _project_dir,
         _catalog
       ),
       do: {:ok, execution}

  defp execution_context(
         %Manifest{command: command},
         _ctx,
         config,
         workspace,
         project_dir,
         catalog
       )
       when is_list(command),
       do:
         Policy.restricted(config, workspace, project_dir, Catalog.implementation_roots(catalog))

  defp execution_context(%Manifest{module: module}, _ctx, config, workspace, project_dir, catalog)
       when is_binary(module) do
    with {:ok, mod} <- module(module) do
      if function_exported?(mod, :run, 2) do
        Policy.restricted(config, workspace, project_dir, Catalog.implementation_roots(catalog))
      else
        {:ok, nil}
      end
    end
  end

  defp execution_context(_manifest, _ctx, _config, _workspace, _project_dir, _catalog),
    do: {:ok, nil}

  defp module(name) do
    atom = String.to_existing_atom("Elixir." <> name)

    if Code.ensure_loaded?(atom), do: {:ok, atom}, else: {:error, {:no_module, name}}
  rescue
    ArgumentError -> {:error, {:no_module, name}}
  end

  defp stringify(event), do: Map.new(event, fn {key, value} -> {to_string(key), value} end)

  defp augment(%{ok: true, emit: emits} = out, events) do
    case request_emit_name(emits) do
      nil ->
        out

      name ->
        if Enum.any?(events, &(&1.type in ["request", "deny"])) do
          out
        else
          %{out | output: out.output <> "\n#{Out.already_granted(name)}"}
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

  defp advance(project, catalog, %{type: "tool", body: body} = event, _via, :hooks) do
    name = Jason.decode!(body)["name"]

    case Map.get(catalog, name) do
      %Manifest{kind: "hook", agent: agent} when not is_nil(agent) ->
        with :ok <- open_reaction_run(project, event, name, agent), do: {:ok, name}

      _not_a_calling_hook ->
        {:ok, name}
    end
  end

  defp advance(_project, _catalog, %{type: "tool", body: body}, _via, :actions),
    do: {:ok, Jason.decode!(body)["name"]}

  defp advance(project, _catalog, %{type: "prompt"} = event, via, :actions) do
    with :ok <-
           open_run(
             project,
             open_params(prompt_id: event.prompt_id, work_id: event.work_id, via: via)
           ),
         do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "grant"} = event, via, :actions) do
    with :ok <- apply_grant(project, event),
         :ok <- open_grant_run(project, event, via) do
      {:ok, via}
    end
  end

  defp advance(project, _catalog, %{type: "continue"} = event, via, :actions) do
    with :ok <- open_continue_run(project, event, via), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "delegate"} = event, via, :actions) do
    with :ok <-
           open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via)),
         do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "request"} = event, via, :actions) do
    with :ok <- open_request_run(project, event, via), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "work"} = event, via, :actions) do
    with :ok <- open_finished_work_run(project, event, via), do: {:ok, via}
  end

  defp advance(_project, _catalog, _event, via, _phase), do: {:ok, via}

  defp open_params(prompt_id: prompt_id, work_id: work_id, via: via),
    do: %{prompt_id: prompt_id, work_id: work_id, request_id: nil, via: via, agent: nil}

  defp open_reaction_run(project, event, hook_name, agent) do
    open_run(
      project,
      %{
        prompt_id: nil,
        work_id: event.work_id,
        request_id: event.request_id,
        inbox_id: event.inbox_id,
        via: hook_name,
        agent: agent
      }
    )
  end

  defp apply_grant(project, event) do
    body = Jason.decode!(event.body)

    case body["scope"] do
      "agent" ->
        Config.grant(project.config_path, {:agent, body["agent"]}, body["name"])

      "depth" ->
        Config.grant(project.config_path, {:depth, body["depth"]}, body["name"])

      "stage" ->
        Config.grant(project.config_path, {:stage, body["workflow"], body["stage"]}, body["name"])

      "workspace" ->
        Config.grant(project.config_path, {:workspace, body["workspace"]}, body["name"])

      _ ->
        :ok
    end
  end

  defp open_grant_run(_project, %{work_id: nil}, _via), do: :ok

  defp open_grant_run(project, %{work_id: work_id, request_id: request_id}, via) do
    open_run(
      project,
      %{prompt_id: nil, work_id: work_id, request_id: request_id, via: via, agent: nil}
    )
  end

  defp open_continue_run(project, event, via) do
    case Jason.decode!(event.body) do
      %{"to" => to} when not is_nil(to) ->
        open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via))

      %{"parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(project, open_params(prompt_id: nil, work_id: parent_id, via: via))

      _no_next_run ->
        :ok
    end
  end

  defp open_request_run(project, event, via) do
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
                 }
               ),
             do: :ok

      _no_agent_arbiter ->
        :ok
    end
  end

  defp open_finished_work_run(project, event, via) do
    case Jason.decode!(event.body) do
      %{"start" => true} ->
        open_run(project, open_params(prompt_id: nil, work_id: event.work_id, via: via))

      %{"state" => "done", "parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(
          project,
          %{prompt_id: nil, work_id: parent_id, request_id: nil, via: nil, agent: nil}
        )

      _no_parent_to_wake ->
        :ok
    end
  end

  defp open_run(project, params) do
    case Run.open(project, params) do
      {:ok, _run} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
