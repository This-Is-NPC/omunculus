defmodule Omunculus.Harness do
  @moduledoc """
  Dispatches a tool `name` to its manifest per spec §7 and §8.7: resolves
  the catalog (rescanned on every call), checks the trigger, hydrates the
  views the manifest declared, invokes the contract, records the call and
  its emits as one transaction, and opens a run for every `prompt` emit
  that follows.
  """

  alias Omunculus.{Project, Run, Store}
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

  @spec dispatch(Project.t(), String.t(), map, map) :: {:ok, map} | {:error, term}
  def dispatch(project, name, args, ctx) do
    with {:ok, manifest} <- manifest(project, name),
         :ok <- check_trigger(manifest, name, ctx.trigger),
         {:ok, view} <- hydrate_views(project, manifest.views, ctx),
         input = %{
           name: name,
           args: args,
           view: view,
           run_id: ctx.run_id,
           work_id: ctx.work_id,
           workspace: nil,
           roots: [project.dir]
         },
         {:ok, out} <- Invoke.call(manifest, input),
         emits = if(out.ok, do: out.emit, else: []),
         call = %{name: name, args: args, ok: out.ok, output: out.output},
         {:ok, events} <-
           Store.record_tool(project.conn, ctx.run_id, call, emits, %{
             run_id: ctx.run_id,
             author: ctx.author
           }),
         :ok <- open_follow_ups(project, events, ctx) do
      {:ok, out}
    end
  end

  defp check_trigger(manifest, name, trigger) do
    if Manifest.triggered_by?(manifest, trigger),
      do: :ok,
      else: {:error, {:not_triggered, name, trigger}}
  end

  defp hydrate_views(project, names, ctx) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_view_id(name, ctx) do
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

  defp resolve_view_id(name, ctx) when name in ["work", "comments.work"], do: {:ok, ctx.work_id}
  defp resolve_view_id("events.run", ctx), do: {:ok, ctx.run_id}
  defp resolve_view_id(name, _ctx), do: {:error, {:unknown_view, name}}

  defp open_follow_ups(project, events, ctx) do
    events
    |> Enum.filter(&(&1.type == "prompt"))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case Run.open(project, event.prompt_id, ctx.model) do
        {:ok, _run} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
