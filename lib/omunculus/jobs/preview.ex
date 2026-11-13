defmodule Omunculus.Jobs.Preview do
  @moduledoc """
  What a job would do, before it exists: the next fires of a schedule and an
  estimate of what each costs, read from the history of its target. The
  estimate is the mean cost of the target's latest fires in jobs, or,
  with none, of its last runs; with neither it is `nil` and `basis` says
  that, so a figure is never made up.
  """

  alias Omunculus.Jobs
  alias Omunculus.Jobs.{Cost, Fields, Schedule}
  alias Omunculus.Store.Query

  @fires 3
  @sample 10

  @doc """
  The preview of `params`: `"schedule"`, `"timezone"` and a `"target"` that
  holds an `"agent"`, a `"workflow"` or a `"tool"`, which runs with no model
  and has no estimate. Gives `"next"` (ISO 8601 instants),
  `"estimate_usd"` and `"basis"`.
  """
  @spec build(Omunculus.Store.Connection.t(), Omunculus.Config.t(), map) ::
          {:ok, map} | {:error, term}
  def build(_conn, %{jobs: nil}, _params), do: {:error, {:jobs, :disabled}}

  def build(conn, config, params) when is_map(params) do
    with {:ok, schedule} <- Fields.parse(params["schedule"], params["timezone"]),
         {:ok, kind, name} <- target(params["target"], config),
         {:ok, samples, source} <- samples(conn, config, kind, name) do
      {:ok,
       %{
         "next" => schedule |> Schedule.next_fires(@fires) |> Enum.map(&DateTime.to_iso8601/1),
         "estimate_usd" => mean(samples),
         "basis" => basis(samples, source, kind, name)
       }}
    end
  end

  def build(_conn, _config, _params), do: {:error, {:jobs, {:invalid, "target"}}}

  defp target(%{"agent" => name}, config) when is_binary(name) do
    case config.agents do
      %{^name => %{depth: 0, workflow_only: false}} -> {:ok, "agent", name}
      _ -> {:error, {:jobs, {:unknown_agent, name}}}
    end
  end

  defp target(%{"workflow" => name}, config) when is_binary(name) do
    if Map.has_key?(config.workflows, name),
      do: {:ok, "workflow", name},
      else: {:error, {:jobs, {:unknown_workflow, name}}}
  end

  defp target(%{"tool" => name}, _config) when is_binary(name), do: {:ok, "tool", name}

  defp target(_target, _config), do: {:error, {:jobs, {:invalid, "target"}}}

  defp mean([]), do: nil
  defp mean(samples), do: Enum.sum(samples) / length(samples)

  defp basis(_samples, :tool, _kind, name),
    do: "the tool #{name} runs with no model, so there is no model cost to estimate"

  defp basis([], _source, kind, name),
    do:
      "no fires of jobs or runs of the #{kind} #{name} to estimate from yet, so there is no estimate"

  defp basis(samples, :fires, kind, name),
    do: "the mean of the #{length(samples)} latest fires of jobs that run the #{kind} #{name}"

  defp basis(samples, :runs, kind, name),
    do:
      "the mean of the #{length(samples)} latest runs of the #{kind} #{name}, their model calls at the models' prices"

  defp samples(_conn, _config, "tool", _name), do: {:ok, [], :tool}

  defp samples(conn, config, kind, name) do
    with {:ok, fired} <- fired(conn, kind, name) do
      if fired == [] do
        with {:ok, runs} <- runs(conn, config, kind, name), do: {:ok, runs, :runs}
      else
        {:ok, fired, :fires}
      end
    end
  end

  # The cost of the latest fires that ran, of the jobs aimed at the target.
  defp fired(conn, kind, name) do
    with {:ok, jobs} <- Jobs.list(conn) do
      jobs
      |> Enum.filter(&(&1[kind] == name))
      |> Enum.reduce_while({:ok, []}, fn job, {:ok, acc} ->
        case Jobs.fires(conn, job["id"]) do
          {:ok, fires} -> {:cont, {:ok, acc ++ fires}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fires} ->
          {:ok,
           fires
           |> Enum.filter(&(&1["state"] in ~w(succeeded failed) and is_number(&1["usd"])))
           |> Enum.sort_by(& &1["at"], :desc)
           |> Enum.take(@sample)
           |> Enum.map(& &1["usd"])}

        error ->
          error
      end
    end
  end

  # The cost of the latest runs of an agent without a work, or of the works
  # a workflow opened as roots, with everything they caused.
  defp runs(conn, config, "agent", name) do
    with {:ok, rows} <-
           Query.all(
             conn,
             "SELECT id FROM runs WHERE agent = ? AND work_id IS NULL AND status = 'done' ORDER BY started_at DESC LIMIT ?",
             [name, @sample]
           ) do
      costs(conn, config, Enum.map(rows, &[&1.id]), true)
    end
  end

  defp runs(conn, config, "workflow", name) do
    with {:ok, roots} <-
           Query.all(
             conn,
             "SELECT id FROM works WHERE workflow = ? AND parent_id IS NULL ORDER BY created_at DESC LIMIT ?",
             [name, @sample]
           ) do
      roots
      |> Enum.map(& &1.id)
      |> Enum.reduce_while({:ok, []}, fn root, {:ok, acc} ->
        case Query.all(
               conn,
               """
               WITH RECURSIVE tree(id) AS (
                 SELECT ?1 UNION SELECT works.id FROM works JOIN tree ON works.parent_id = tree.id)
               SELECT id FROM runs WHERE work_id IN tree
               """,
               [root]
             ) do
          {:ok, rows} -> {:cont, {:ok, acc ++ [Enum.map(rows, & &1.id)]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, groups} -> costs(conn, config, groups, false)
        error -> error
      end
    end
  end

  # `below`: add the runs each caused, as a run without a work has them below.
  defp costs(conn, config, groups, below) do
    Enum.reduce_while(groups, {:ok, []}, fn ids, {:ok, acc} ->
      with {:ok, caused} <- if(below, do: below(conn, ids), else: {:ok, []}),
           {:ok, cost} <- Cost.of_runs(conn, config, Enum.uniq(ids ++ caused)) do
        {:cont, {:ok, acc ++ [cost.usd]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp below(conn, run_ids) do
    with {:ok, events} <-
           Query.all(
             conn,
             "SELECT id FROM events WHERE run_id IN (#{Query.placeholders(run_ids)})",
             run_ids
           ),
         do: Cost.runs(conn, Enum.map(events, & &1.id))
  end
end
