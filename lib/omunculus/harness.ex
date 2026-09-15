defmodule Omunculus.Harness do
  @moduledoc """
  Dispatches a tool `name` to its manifest per spec §7, §8.7 and §5:
  resolves the catalog (rescanned on every call), checks the trigger,
  derives the run's `work_id` from the store so a work created mid-run is
  visible to the next call without the model passing ids around, hydrates
  the views the manifest declared, loads the project's config for the
  action layer, invokes the contract, and records the call and its emits
  as one transaction. Augments the output with "already granted: <name>"
  when a `request_access` call asked for a name the run already has.

  `dispatch/4` never opens a run itself. `follow_up/3` walks a list of
  events in order — the run's own replay, or the events a single
  `dispatch/4` call produced — remembering the last `tool` event's name as
  `via`, and opens the run each event asks for per spec §3.2 and §3.4: a
  `prompt` opens a run on its work, a `grant` applies a permanent ceiling
  change when scoped and reopens a run on its work, a `continue` reopens a
  run on the same work when it moved to a next stage or on the parent when
  it closed one waiting on it, a `delegate` opens a run on the child, a
  `request` with an agent arbiter opens a run on the arbiter's work, and a
  `work` closed by `finish_work` reopens a run on its parent.
  """

  alias Omunculus.{Config, Project, Run, Store}
  alias Omunculus.Tool.{Catalog, Invoke, Manifest}

  @spec manifest(Project.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, {:unknown_tool, String.t()}}
  def manifest(%Project{dir: dir}, name) do
    catalog = Catalog.discover(Catalog.roots(dir))

    case Map.fetch(catalog, name) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  @spec dispatch(Project.t(), String.t(), map, map) :: {:ok, map, [map]} | {:error, term}
  def dispatch(project, name, args, ctx) do
    with {:ok, manifest} <- manifest(project, name),
         :ok <- check_trigger(manifest, name, ctx.trigger),
         {:ok, work_id} <- resolve_work_id(project, ctx.run_id),
         {:ok, view} <- hydrate_views(project, manifest.views, ctx.run_id, work_id),
         {:ok, config} <- Config.load(project.dir),
         input = %{
           name: name,
           args: args,
           view: view,
           run_id: ctx.run_id,
           work_id: work_id,
           workspace: nil,
           roots: [project.dir]
         },
         {:ok, out} <- Invoke.call(manifest, input),
         emits = if(out.ok, do: out.emit, else: []),
         call = %{name: name, args: args, ok: out.ok, output: out.output},
         {:ok, events} <-
           Store.record_tool(project.conn, ctx.run_id, call, emits, %{
             run_id: ctx.run_id,
             work_id: work_id,
             author: ctx.author,
             agent: ctx.agent,
             config: config
           }) do
      {:ok, augment(out, emits, events), events}
    end
  end

  @spec follow_up(Project.t(), [map], (String.t(), fun -> {:ok, String.t()} | {:error, term})) ::
          :ok | {:error, term}
  def follow_up(project, events, model) do
    events
    |> Enum.reduce_while({:ok, nil}, fn event, {:ok, via} ->
      case advance(project, event, via, model) do
        {:ok, _via} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _via} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp check_trigger(manifest, name, trigger) do
    if Manifest.triggered_by?(manifest, trigger),
      do: :ok,
      else: {:error, {:not_triggered, name, trigger}}
  end

  defp resolve_work_id(_project, nil), do: {:ok, nil}

  defp resolve_work_id(project, run_id) do
    case Store.view(project.conn, "run", run_id) do
      {:ok, nil} -> {:error, {:no_run, run_id}}
      {:ok, run} -> {:ok, run.work_id}
      {:error, _reason} = error -> error
    end
  end

  defp hydrate_views(project, names, run_id, work_id) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_view_id(name, run_id, work_id) do
        {:error, _reason} = error -> {:halt, error}
        {:ok, nil} -> {:cont, {:ok, acc}}
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

  defp resolve_view_id(name, _run_id, work_id) when name in ["work", "comments.work"],
    do: {:ok, work_id}

  defp resolve_view_id("events.run", run_id, _work_id), do: {:ok, run_id}
  defp resolve_view_id(name, _run_id, _work_id), do: {:error, {:unknown_view, name}}

  defp augment(out, emits, events) do
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

  defp request_emit_name(emits) do
    Enum.find_value(emits, fn
      %{"type" => "request", "body" => %{"name" => name}} -> name
      _ -> nil
    end)
  end

  defp advance(_project, %{type: "tool", body: body}, _via, _model),
    do: {:ok, Jason.decode!(body)["name"]}

  defp advance(project, %{type: "prompt"} = event, via, model) do
    with :ok <-
           open_run(
             project,
             %{prompt_id: event.prompt_id, work_id: event.work_id, request_id: nil, via: via},
             model
           ),
         do: {:ok, via}
  end

  defp advance(project, %{type: "grant"} = event, via, model) do
    with :ok <- apply_grant(project, event),
         :ok <- open_grant_run(project, event, via, model) do
      {:ok, via}
    end
  end

  defp advance(project, %{type: "continue"} = event, via, model) do
    with :ok <- open_continue_run(project, event, via, model), do: {:ok, via}
  end

  defp advance(project, %{type: "delegate"} = event, via, model) do
    with :ok <-
           open_run(
             project,
             %{prompt_id: nil, work_id: event.work_id, request_id: nil, via: via},
             model
           ),
         do: {:ok, via}
  end

  defp advance(project, %{type: "request"} = event, via, model) do
    with :ok <- open_request_run(project, event, via, model), do: {:ok, via}
  end

  defp advance(project, %{type: "work"} = event, via, model) do
    with :ok <- open_finished_work_run(project, event, model), do: {:ok, via}
  end

  defp advance(_project, _event, via, _model), do: {:ok, via}

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
    do: open_run(project, %{prompt_id: nil, work_id: work_id, request_id: nil, via: via}, model)

  defp open_continue_run(project, event, via, model) do
    case Jason.decode!(event.body) do
      %{"to" => to} when not is_nil(to) ->
        open_run(
          project,
          %{prompt_id: nil, work_id: event.work_id, request_id: nil, via: via},
          model
        )

      %{"parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(project, %{prompt_id: nil, work_id: parent_id, request_id: nil, via: via}, model)

      _no_next_run ->
        :ok
    end
  end

  defp open_request_run(project, event, via, model) do
    case Jason.decode!(event.body) do
      %{"arbiter" => _arbiter, "arbiter_work_id" => work_id} ->
        open_run(
          project,
          %{prompt_id: nil, work_id: work_id, request_id: event.request_id, via: via},
          model
        )

      _no_agent_arbiter ->
        :ok
    end
  end

  defp open_finished_work_run(project, event, model) do
    case Jason.decode!(event.body) do
      %{"state" => "done", "parent_id" => parent_id} when not is_nil(parent_id) ->
        open_run(project, %{prompt_id: nil, work_id: parent_id, request_id: nil, via: nil}, model)

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
