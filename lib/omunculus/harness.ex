defmodule Omunculus.Harness do
  @moduledoc """
  Dispatches a tool `name` to its manifest per spec §7, §8.7 and §5:
  discovers the catalog once (rescanned on every call, then reused for the
  whole dispatch), checks the trigger, reads the run row once when
  `ctx.run_id` is set so both the run's `work_id` and its own `tools` are
  visible to the next call without the model passing ids around, hydrates
  the views the manifest declared — `"catalog"` from the run's own
  `tools` filtered to the model-triggered names still on disk, sorted by
  name, `[]` outside a run — loads the project's config and the catalog's
  group map for the action layer, invokes the contract, and records the
  call and its emits as one transaction. After that,
  every emit event runs the hooks `Catalog.hooks_for/2` finds for its
  `type` through the same contract, each recorded as its own call; a hook
  never reacts to another hook's emits. Augments the output with "already
  granted: <name>" when a `request_access` call asked for a name the run
  already has, based on the original call's own events only.

  `dispatch/4` never opens a run itself. `follow_up/3` walks a list of
  events in order twice — the run's own replay, or the events a single
  `dispatch/4` call produced — remembering the last `tool` event's name as
  `via`. The first pass opens the run each *action* event asks for per
  spec §3.2 and §3.4: a `prompt` opens a run on its work, a `grant`
  applies a permanent ceiling change when scoped and reopens a run on its
  work, a `continue` reopens a run on the same work when it moved to a
  next stage or on the parent when it closed one waiting on it, a
  `delegate` opens a run on the child, a `request` with an agent arbiter
  opens a run on the arbiter's work, a `work` closed by `finish_work`
  reopens a run on its parent. Only once every action of this list has
  been sequenced does the second pass open a run for each `tool` event
  whose name resolves to a hook declaring an `agent`, `via` the hook's
  name — a hook reacts like any other run, but per spec §6 it never
  sequences the protocol itself, so it never gets to run ahead of the
  action cascade its own trigger belongs to.
  """

  alias Omunculus.{Config, Project, Run, Store}
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}

  @spec manifest(Project.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, {:unknown_tool, String.t()}}
  def manifest(%Project{dir: dir}, name) do
    dir |> Catalog.roots() |> Catalog.discover() |> fetch_manifest(name)
  end

  @spec dispatch(Project.t(), String.t(), map, map) :: {:ok, map, [map]} | {:error, term}
  def dispatch(project, name, args, ctx) do
    catalog = project.dir |> Catalog.roots() |> Catalog.discover()

    with {:ok, manifest} <- fetch_manifest(catalog, name),
         :ok <- check_trigger(manifest, name, ctx.trigger),
         {:ok, run} <- resolve_run(project, ctx.run_id),
         work_id = run_work_id(run),
         catalog_view = catalog_view(run, catalog),
         {:ok, config} <- Config.load(project.dir),
         {:ok, out, events} <-
           call(project, manifest, args, work_id, ctx, config, catalog, catalog_view),
         {:ok, hook_events} <-
           run_hooks(project, catalog, events, work_id, ctx, config, catalog_view) do
      {:ok, augment(out, events), events ++ hook_events}
    end
  end

  @spec follow_up(Project.t(), [map], (String.t(), fun -> {:ok, String.t()} | {:error, term})) ::
          :ok | {:error, term}
  def follow_up(project, events, model) do
    catalog = project.dir |> Catalog.roots() |> Catalog.discover()

    with {:ok, _via} <- walk(project, catalog, events, model, :actions),
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
      groups: Catalog.groups(catalog)
    }

  defp hydrate_views(project, names, run_id, work_id, catalog_view) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_view_id(name, run_id, work_id) do
        {:error, _reason} = error -> {:halt, error}
        :skip -> {:cont, {:ok, acc}}
        :catalog -> {:cont, {:ok, Map.put(acc, "catalog", catalog_view)}}
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

  defp resolve_view_id(name, _run_id, work_id) when name in ["work", "comments.work"] do
    if work_id, do: {:ok, work_id}, else: :skip
  end

  defp resolve_view_id("events.run", run_id, _work_id) do
    if run_id, do: {:ok, run_id}, else: :skip
  end

  defp resolve_view_id("inbox", _run_id, _work_id), do: {:ok, nil}
  defp resolve_view_id("catalog", _run_id, _work_id), do: :catalog
  defp resolve_view_id(name, _run_id, _work_id), do: {:error, {:unknown_view, name}}

  defp run_hooks(
         project,
         catalog,
         [_tool_event | emit_events],
         work_id,
         ctx,
         config,
         catalog_view
       ) do
    Enum.reduce_while(emit_events, {:ok, []}, fn event, {:ok, acc} ->
      case run_hooks_for(project, catalog, event, work_id, ctx, config, catalog_view) do
        {:ok, hook_events} -> {:cont, {:ok, acc ++ hook_events}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp run_hooks_for(project, catalog, event, work_id, ctx, config, catalog_view) do
    catalog
    |> Catalog.hooks_for(event.type)
    |> Enum.reduce_while({:ok, []}, fn hook, {:ok, acc} ->
      case invoke_hook(project, hook, event, work_id, ctx, config, catalog, catalog_view) do
        {:ok, hook_events} -> {:cont, {:ok, acc ++ hook_events}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp invoke_hook(project, hook, event, work_id, ctx, config, catalog, catalog_view) do
    with {:ok, _out, events} <-
           call(
             project,
             hook,
             %{"event" => stringify(event)},
             work_id,
             ctx,
             config,
             catalog,
             catalog_view
           ) do
      {:ok, events}
    end
  end

  defp call(project, manifest, args, work_id, ctx, config, catalog, catalog_view) do
    with {:ok, view} <- hydrate_views(project, manifest.views, ctx.run_id, work_id, catalog_view),
         input = %{
           name: manifest.name,
           args: args,
           view: view,
           run_id: ctx.run_id,
           work_id: work_id,
           workspace: nil,
           roots: [project.dir]
         },
         {:ok, out} <- Invoke.call(manifest, input),
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
    with :ok <- open_finished_work_run(project, event, model), do: {:ok, via}
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
        via: hook_name,
        agent: agent
      },
      model
    )
  end

  defp apply_grant(project, event) do
    body = Jason.decode!(event.body)

    case body["scope"] do
      "agent" -> Config.grant(project.dir, {:agent, body["agent"]}, body["name"])
      "depth" -> Config.grant(project.dir, {:depth, body["depth"]}, body["name"])
      _ -> :ok
    end
  end

  defp open_grant_run(_project, %{work_id: nil}, _via, _model), do: :ok

  defp open_grant_run(project, %{work_id: work_id}, via, model),
    do: open_run(project, open_params(prompt_id: nil, work_id: work_id, via: via), model)

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
      %{"arbiter" => _arbiter, "arbiter_work_id" => work_id} ->
        with :ok <-
               open_run(
                 project,
                 %{
                   prompt_id: nil,
                   work_id: work_id,
                   request_id: event.request_id,
                   via: via,
                   agent: nil
                 },
                 model
               ),
             do: :ok

      _no_agent_arbiter ->
        :ok
    end
  end

  defp open_finished_work_run(project, event, model) do
    case Jason.decode!(event.body) do
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
