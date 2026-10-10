defmodule Omunculus.Harness do
  @moduledoc """
  Discovers and dispatches tool names through the shared contract. The
  catalog a call sees has the `overrides` of its run applied, or those of
  the policy and workspace layers outside a run. Hydrates declared views,
  runs the steps a call chains (`out.chain`, then the manifest's `then`)
  under the same contract, commits the call, its steps and all their
  emits atomically, then reacts to their events. A step
  outside the chaining tool's `chains`, without the `chain` trigger, not
  have in the run's ceiling, already on the chain path, after `end`, or
  failing fails the call and writes none of the chain's emits; a call
  outside a run checks no ceiling. Run lifecycle events use the same
  `react/2` path. The `request` view is the request named by the call's
  `request_id` argument, or else the run's; `grant_scopes` is the list of
  scopes the store accepts on a permanent grant.

  Hooks use the same emit path as tools. Hooks of every event run during
  the model unroll except those of `end`, the only event that ends a run:
  they wait until `follow_up/3` runs after the run has closed and the
  runs its events ask for are due. `open_due/2` writes the permanent
  grants among the events to the TOML and makes the runs their actions
  ask for due in the `Omunculus.Cycle`, which opens them concurrently;
  `follow_up/3` does the same, then runs those deferred hooks, then makes
  the reaction runs of calling hooks due, preserving the originating tool
  or hook in `via`. A `reply` opens a run of the requester's work when
  that work is open after the reply and its option's calls, and, for a
  request from a run without a work, a run of that run's agent in its
  conversation. The `runs.request` view is the run that opened the run's
  request.
  """

  alias Omunculus.{Ceiling, Config, Cycle, Project, Secrets, Skills, Store}
  alias Omunculus.Execution.Policy
  alias Omunculus.Store.Actions.Requests
  alias Omunculus.Tool.{Catalog, Invoke, Manifest, Overrides, Views}
  alias Omunculus.Tools.Out

  @spec manifest(Project.t(), String.t()) :: {:ok, Manifest.t()} | {:error, term}
  def manifest(%Project{} = project, name) do
    with {:ok, config} <- resolved_config(project, nil),
         {:ok, catalog} <- catalog(nil, nil, config, workspace_context(config, nil), nil) do
      fetch_dispatch_manifest(catalog, name, "cli")
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
         workspace = workspace_context(config, work),
         {:ok, catalog} <- catalog(project, run, config, workspace, Map.get(ctx, :execution)),
         {:ok, manifest} <- fetch_dispatch_manifest(catalog, name, ctx.trigger),
         :ok <- check_trigger(manifest, name, ctx.trigger),
         views =
           views(project, run, work, config, catalog, workspace, %{
             request_id: run && run.request_id,
             inbox_id: run_inbox_id(project, run)
           }),
         {:ok, out, events} <-
           call(project, manifest, args, work_id, ctx, config, catalog, views, workspace),
         {:ok, hook_events} <-
           maybe_react(project, events, [], Map.get(ctx, :execution)) do
      {:ok, out, events ++ hook_events}
    end
  end

  @doc "Dispatches reactions to committed events, including the run lifecycle."
  def react(project, events, active \\ [], execution \\ nil) do
    with {:ok, base} <- Config.load(project.config_path) do
      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
        with {:ok, run} <- resolve_run(project, event.run_id),
             {:ok, work} <- fetch_work(project, event.work_id),
             {:ok, config} <-
               Config.for_workspace(base, Config.effective_workspace(base, work)),
             workspace = workspace_context(config, work),
             {:ok, catalog} <- catalog(project, run, config, workspace, execution) do
          ctx = %{
            run_id: event.run_id,
            author: if(run, do: "agent", else: "human"),
            agent: run && run.agent,
            issuer: Map.get(event, :actor_issuer),
            subject: Map.get(event, :actor_subject),
            origin_issuer: Map.get(event, :origin_issuer),
            origin_subject: Map.get(event, :origin_subject),
            conversation_id: Map.get(event, :conversation_id),
            request_id: event.request_id,
            inbox_id: event.inbox_id,
            via: run && run.via,
            execution: execution
          }

          views =
            views(project, run, work, config, catalog, workspace, %{
              request_id: event.request_id,
              inbox_id: event.inbox_id
            })

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

  # What a call's views read that the harness computes rather than the
  # store — the catalog, workspaces, agents, paths, grant scopes and skills
  # of the run, each computed only when a view asks for it — plus the request and
  # inbox ids `ids` names, which anchor its views.
  defp views(project, run, work, config, catalog, workspace, ids) do
    Map.put(ids, :computed, %{
      "catalog" => fn _spec -> catalog_view(run, catalog, start_event(project, run)) end,
      "workspaces" => fn _spec -> workspaces_view(config, workspace.name) end,
      "agents" => fn spec -> agents_view(project, config, work, catalog, workspace, spec) end,
      "paths" => fn _spec -> path_permissions(project, run, workspace) end,
      "grant_scopes" => fn _spec -> Requests.scopes() end,
      "skills" => fn _spec -> skills_view(project, run, catalog) end
    })
  end

  # The skills the run has, among the names its mounted ceiling has.
  defp skills_view(project, run, catalog) do
    names = (run_ceiling(project, run) || %{}) |> Map.get("have", []) |> Enum.sort()

    for name <- names, %Manifest{kind: "skill"} = skill <- [Map.get(catalog, name)] do
      %{name: Skills.short_name(name), description: skill.description, dir: skill.dir}
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

  defp run_ceiling(project, run) do
    case start_event(project, run) do
      nil -> nil
      event -> Jason.decode!(event.body)["ceiling"]
    end
  end

  # The catalog a call sees: a run's overrides come from its mounted
  # snapshot; outside a run only the policy and workspace layers apply.
  defp catalog(project, run, config, workspace, execution) do
    config.tools
    |> Catalog.discover(config.mcp, execution, &Secrets.resolve(config, &1.secrets))
    |> Overrides.apply(run_overrides(project, run, config, workspace))
  end

  defp run_overrides(_project, nil, config, workspace),
    do:
      Ceiling.overrides(config, %{agent: nil, depth: nil, stage: nil, workspace: workspace.layer})

  defp run_overrides(project, run, _config, _workspace) do
    case run_ceiling(project, run) do
      nil -> %{}
      ceiling -> ceiling["overrides"]
    end
  end

  defp path_permissions(project, run, workspace) do
    case run_ceiling(project, run) do
      nil -> %{}
      ceiling -> Ceiling.paths(ceiling, workspace.root || project.dir)
    end
  end

  @doc """
  Opens the runs `events` ask for, then runs the hooks of the ending
  events among them, then opens the reaction runs of the calling hooks
  among `opened ++ events`. `opened` are earlier events of the same run
  whose runs `open_due/2` already opened.
  """
  @spec follow_up(Project.t(), [map], [map]) :: :ok | {:error, term}
  def follow_up(project, events, opened \\ []) do
    Cycle.run(project, nil, fn project ->
      with :ok <- open(project, events),
           {:ok, catalog} <- follow_catalog(project),
           {:ok, _hooks} <- react(project, Enum.filter(events, &ending_event?/1), []),
           {:ok, _via} <- walk(project, catalog, opened ++ events, :hooks) do
        :ok
      end
    end)
  end

  @doc "Writes the permanent grants among `events` and opens the runs their actions ask for."
  @spec open_due(Project.t(), [map]) :: :ok | {:error, term}
  def open_due(project, events) do
    Cycle.run(project, nil, &open(&1, events))
  end

  defp follow_catalog(project) do
    with {:ok, config} <- resolved_config(project, nil) do
      {:ok, Catalog.discover(config.tools, config.mcp, nil)}
    end
  end

  # Only the calling hooks walk needs the catalog.
  defp open(project, events) do
    with :ok <- write_grants(project, events),
         {:ok, _via} <- walk(project, nil, events, :actions),
         do: :ok
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

  defp fetch_dispatch_manifest(catalog, name, trigger) when trigger in ["cli", "harness"] do
    case fetch_manifest(catalog, name) do
      {:ok, _manifest} = ok ->
        ok

      {:error, {:unknown_tool, ^name}} ->
        case Map.fetch(Catalog.unconfigured(), name) do
          {:ok, %Manifest{config: true} = manifest} ->
            if Manifest.triggered_by?(manifest, trigger),
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

  # The agents a new work may name: those of the depth below the call's
  # run, to which a run without a work hands its works down too; when that
  # depth has a workflow, the workflow and its stages instead. With
  # `tools`, each agent comes with the model tools its own ceiling has at
  # that depth.
  defp agents_view(project, config, work, catalog, workspace, spec) do
    depth = if work, do: Store.work_depth(project.conn, work) + 1, else: 1

    case Config.workflow_for(config, depth) do
      :off ->
        names = config |> Config.agents_at_depth(depth) |> Enum.map(fn {name, _agent} -> name end)

        if "tools" in spec.include,
          do:
            Enum.map(
              names,
              &%{name: &1, tools: agent_tools(config, &1, depth, catalog, workspace)}
            ),
          else: names

      {:ok, steps} ->
        [
          %{
            workflow: Config.workflow_name_for(config, depth),
            stages: Enum.map(steps, &%{name: &1.name, agent: &1.agent})
          }
        ]
    end
  end

  defp agent_tools(config, agent, depth, catalog, workspace) do
    model_catalog = Catalog.with_trigger(catalog, "model")

    snapshot =
      Ceiling.mount(
        config,
        %{
          agent: agent,
          depth: depth,
          grants: [],
          stage: nil,
          groups: Catalog.groups(catalog),
          workspace: workspace.layer
        },
        Map.keys(model_catalog)
      )

    snapshot.have |> Enum.filter(&Map.has_key?(model_catalog, &1)) |> Enum.sort()
  end

  defp catalog_view(nil, _catalog, _event), do: []

  defp catalog_view(%{tools: tools}, catalog, event) do
    model_catalog = Catalog.with_trigger(catalog, "model")
    names = if tools, do: Jason.decode!(tools), else: []
    pinned = event_pinned(event)

    names
    |> Enum.filter(&Map.has_key?(model_catalog, &1))
    |> Enum.sort()
    |> Enum.map(&catalog_card(Map.fetch!(model_catalog, &1), pinned))
  end

  defp event_pinned(nil), do: nil

  defp event_pinned(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ceiling" => %{"pinned" => pinned}}} -> pinned
      _other -> nil
    end
  end

  defp event_pinned(_event), do: nil

  defp catalog_card(
         %Manifest{name: name, description: description, tags: tags, groups: groups},
         pinned
       ) do
    %{
      name: name,
      description: description,
      tags: tags,
      groups: groups,
      pinned: pinned?(pinned, name)
    }
  end

  defp pinned?(nil, _name), do: true
  defp pinned?(list, name) when is_list(list), do: name in list

  defp store_ctx(ctx, work_id, config, catalog),
    do: %{
      run_id: ctx.run_id,
      work_id: work_id,
      author: ctx.author,
      agent: ctx.agent,
      issuer: Map.get(ctx, :issuer),
      subject: Map.get(ctx, :subject),
      origin_issuer: Map.get(ctx, :origin_issuer),
      origin_subject: Map.get(ctx, :origin_subject),
      principal: Map.get(ctx, :principal),
      capability: Map.get(ctx, :capability),
      conversation_id: Map.get(ctx, :conversation_id),
      command_id: Map.get(ctx, :command_id),
      command_hash: Map.get(ctx, :command_hash),
      config: config,
      groups: Catalog.groups(catalog),
      request_id: Map.get(ctx, :request_id),
      inbox_id: Map.get(ctx, :inbox_id)
    }

  # Where a call's views start, and the values the harness computes for it.
  defp view_scope(env, args) do
    %{
      run_id: env.ctx.run_id,
      work_id: env.work_id,
      request_id: env.views.request_id,
      inbox_id: env.views.inbox_id,
      prompt_id: Map.get(env.ctx, :prompt_id),
      args: args,
      computed: env.views.computed
    }
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
    env = %{
      project: project,
      work_id: work_id,
      ctx: ctx,
      config: config,
      catalog: catalog,
      views: views,
      workspace: workspace
    }

    with {:ok, out} <- invoke(env, manifest, args) do
      {out, calls} =
        case chain(env, manifest, out, [manifest.name], [call_entry(manifest, args, out, nil)]) do
          {:ok, calls} ->
            {out, calls}

          {:error, {:chain, name, reason}} ->
            failed = %{out | ok: false, output: Out.chain_failed(name, reason)}
            {failed, [call_entry(manifest, args, failed, nil)]}
        end

      store_ctx = store_ctx(ctx, work_id, config, catalog)

      case Store.record_tools(project.conn, ctx.run_id, calls, store_ctx) do
        {:ok, events} ->
          {:ok, out, events}

        # A model's call the store refuses is recorded as failed, with why,
        # and writes none of its emits: the model reads why and goes on.
        {:error, reason} when ctx.trigger == "model" ->
          refused = %{out | ok: false, output: Out.refused(reason)}
          entry = call_entry(manifest, args, refused, nil)

          with {:ok, events} <- Store.record_tools(project.conn, ctx.run_id, [entry], store_ctx) do
            {:ok, refused, events}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp invoke(env, manifest, args) do
    with {:ok, execution} <-
           execution_context(
             manifest,
             env.ctx,
             env.config,
             env.workspace,
             env.project.dir,
             env.catalog
           ),
         {:ok, view} <- Views.hydrate(env.project.conn, manifest.views, view_scope(env, args)) do
      input = %{
        name: manifest.name,
        args: args,
        view: view,
        run_id: env.ctx.run_id,
        work_id: env.work_id,
        workspace: env.workspace.name,
        roots: if(env.workspace.root, do: [env.workspace.root], else: [env.project.dir]),
        config_path: env.project.config_path
      }

      # A secret goes to the tool's process alone, and out of what it returns.
      with {:ok, secrets} <- Secrets.for_tool(env.config, manifest) do
        manifest
        |> Invoke.call(input, execution, secrets)
        |> Secrets.mask(secrets)
      end
    end
  end

  defp call_entry(manifest, args, out, via) do
    record = %{name: manifest.name, args: args, ok: out.ok, output: out.output}
    record = if via, do: Map.put(record, :via, via), else: record
    {record, if(out.ok, do: out.emit, else: [])}
  end

  # Steps run depth first: a step's own chain runs before the next step.
  # `active` is the path from the called tool to the current one; `calls`
  # is everything executed so far, the called tool first.
  defp chain(_env, _manifest, %{ok: false}, _active, calls), do: {:ok, calls}

  defp chain(env, manifest, out, active, calls) do
    steps = out.chain ++ Enum.map(manifest.then, &%{name: &1, args: %{}})

    Enum.reduce_while(steps, {:ok, calls}, fn step, {:ok, calls} ->
      case chain_step(env, manifest, step, active, calls) do
        {:ok, _calls} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp chain_step(env, parent, %{name: name, args: args}, active, calls) do
    step_env = %{env | ctx: Map.put(env.ctx, :trigger, "chain")}

    with :ok <- chain_check(name, name in parent.chains, :not_chainable),
         :ok <- chain_check(name, name not in active, :loop),
         :ok <- chain_check(name, not Enum.any?(calls, &ended?/1), :after_end),
         {:ok, manifest} <- chain_manifest(env.catalog, name),
         :ok <- chain_check(name, Manifest.triggered_by?(manifest, "chain"), :not_triggered),
         :ok <- chain_check(name, run_has?(env, name), :not_have),
         {:ok, out} <- chain_invoke(step_env, manifest, args),
         :ok <- chain_check(name, out.ok, {:failed, out.output}) do
      chain(
        step_env,
        manifest,
        out,
        [name | active],
        calls ++ [call_entry(manifest, args, out, parent.name)]
      )
    end
  end

  defp chain_check(_name, true, _reason), do: :ok
  defp chain_check(name, false, reason), do: {:error, {:chain, name, reason}}

  defp ended?({%{name: name}, _emits}), do: name == "end"

  defp chain_manifest(catalog, name) do
    case fetch_manifest(catalog, name) do
      {:ok, _manifest} = ok -> ok
      {:error, _reason} -> {:error, {:chain, name, :unknown_tool}}
    end
  end

  defp chain_invoke(env, manifest, args) do
    case invoke(env, manifest, args) do
      {:ok, _out} = ok -> ok
      {:error, reason} -> {:error, {:chain, manifest.name, reason}}
    end
  end

  defp run_has?(%{ctx: %{run_id: nil}}, _name), do: true

  defp run_has?(env, name) do
    {:ok, run} = resolve_run(env.project, env.ctx.run_id)
    Ceiling.classify(run_ceiling(env.project, run), name, "tool") == "have"
  end

  defp maybe_react(project, events, active, execution) do
    react(project, Enum.reject(events, &ending_event?/1), active, execution)
  end

  @spec ending_event?(map) :: boolean
  def ending_event?(event), do: event.type == "end"

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
           due(project, event, %{prompt_id: event.prompt_id, work_id: event.work_id, via: via}),
         do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "reply"} = event, via, :actions) do
    with :ok <- open_reply_run(project, event, via), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: type} = event, via, :actions)
       when type in ["continue", "break", "cancel"] do
    with :ok <- open_sequence_run(project, event, via), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: type} = event, via, :actions)
       when type in ["delegate", "reopen"] do
    with :ok <- due(project, event, %{work_id: event.work_id, via: via}), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "request"} = event, via, :actions) do
    with :ok <- open_request_run(project, event, via), do: {:ok, via}
  end

  defp advance(project, _catalog, %{type: "work"} = event, via, :actions) do
    with :ok <- open_root_run(project, event, via), do: {:ok, via}
  end

  defp advance(_project, _catalog, _event, via, _phase), do: {:ok, via}

  defp open_reaction_run(project, event, hook_name, agent) do
    due(project, event, %{
      work_id: event.work_id,
      request_id: event.request_id,
      inbox_id: event.inbox_id,
      via: hook_name,
      agent: agent
    })
  end

  # Permanent grants reach the TOML before any run the same events open.
  defp write_grants(project, events) do
    events
    |> Enum.filter(&(&1.type == "grant"))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case write_grant(project, Jason.decode!(event.body)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_grant(project, body) do
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

  # The requester's work runs again when it is open once the reply and
  # the calls of its option are applied; without a work, its agent runs
  # again in the requesting run's conversation.
  defp open_reply_run(project, %{work_id: nil, request_id: request_id} = event, via) do
    with {:ok, request} <- Store.view(project.conn, "request", request_id),
         {:ok, run} <- Store.view(project.conn, "run", request.run_id) do
      due(project, event, %{
        request_id: request_id,
        via: via,
        agent: run.agent,
        conversation_id: run.conversation_id
      })
    end
  end

  defp open_reply_run(project, %{work_id: work_id, request_id: request_id} = event, via) do
    case Store.view(project.conn, "work", work_id) do
      {:ok, %{state: "open"}} ->
        due(project, event, %{work_id: work_id, request_id: request_id, via: via})

      {:ok, _not_open} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp open_sequence_run(project, event, via) do
    case {event.type, Jason.decode!(event.body)} do
      {"continue", %{"to" => to}} when not is_nil(to) ->
        due(project, event, %{work_id: event.work_id, via: via})

      {_type, %{"parent_id" => parent_id}} when not is_nil(parent_id) ->
        due(project, event, %{work_id: parent_id, via: via})

      _no_next_run ->
        :ok
    end
  end

  defp open_request_run(project, event, via) do
    case Jason.decode!(event.body) do
      %{"arbiter" => arbiter, "arbiter_work_id" => work_id} ->
        due(project, event, %{
          work_id: work_id,
          request_id: event.request_id,
          via: via,
          agent: arbiter
        })

      _no_agent_arbiter ->
        :ok
    end
  end

  # The run that created the root is linked to it, so it holds the root's
  # turn until it finishes; the root's own run opens after it.
  defp open_root_run(project, event, via) do
    case Jason.decode!(event.body) do
      %{"start" => true} ->
        if event.run_id, do: Cycle.link(project, event.work_id)
        due(project, event, %{work_id: event.work_id, via: via})

      _not_a_new_root ->
        :ok
    end
  end

  defp due(project, event, opening) do
    Cycle.open(
      project,
      Map.merge(opening, %{
        origin_issuer: Map.get(event, :origin_issuer),
        origin_subject: Map.get(event, :origin_subject),
        cause_id: event.id
      })
    )
  end
end
