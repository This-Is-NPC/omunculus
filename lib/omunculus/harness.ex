defmodule Omunculus.Harness do
  @moduledoc """
  Dispatches a tool `name` to its manifest per spec §7, §8.7 and §5:
  resolves the catalog (rescanned on every call), checks the trigger,
  derives the run's `work_id` from the store so a work created mid-run is
  visible to the next call without the model passing ids around, hydrates
  the views the manifest declared, invokes the contract, records the call
  and its emits as one transaction, opens a run for every `prompt` emit
  that follows, and for every `grant` emit applies the ceiling change and
  reopens a run on the same stage. Augments the output with "already
  granted: <name>" when a `request_access` call asked for a name the run
  already has.
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
             agent: ctx.agent
           }),
         :ok <- open_follow_ups(project, events, ctx) do
      {:ok, augment(out, emits, events), events}
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

  defp open_follow_ups(project, events, ctx) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case follow_up(project, event, ctx) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp follow_up(project, %{type: "prompt"} = event, ctx) do
    open_run(project, %{prompt_id: event.prompt_id, work_id: event.work_id}, ctx.model)
  end

  defp follow_up(project, %{type: "grant", work_id: work_id} = event, ctx)
       when not is_nil(work_id) do
    with :ok <- apply_grant(project, event) do
      open_run(project, %{prompt_id: nil, work_id: work_id}, ctx.model)
    end
  end

  defp follow_up(project, %{type: "grant"} = event, _ctx), do: apply_grant(project, event)

  defp follow_up(_project, _event, _ctx), do: :ok

  defp apply_grant(project, event) do
    body = Jason.decode!(event.body)

    case body["scope"] do
      "agent" -> Config.grant(project.dir, {:agent, body["agent"]}, body["name"])
      "depth" -> Config.grant(project.dir, {:depth, body["depth"]}, body["name"])
      _ -> :ok
    end
  end

  defp open_run(project, params, model) do
    case Run.open(project, params, model) do
      {:ok, _run} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
