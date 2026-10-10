defmodule EquivalentExchange.Resources do
  @moduledoc """
  What a run took from the machine, sampled from `/proc` every
  `@interval` ms while it runs: the CPU and memory of the BEAM that runs
  every execution, and each sandboxed process it starts — a process is the
  execution whose workspace its `--chdir` names. `start/0` begins sampling,
  `stop/1` ends it and returns `%{"beam" => [sample], "processes" =>
  [process]}`, and `by_agent/2` attributes it to the agents of the
  executions: a process to the last run of its execution started before it
  was first seen (sampling may see it only after that run closed), the BEAM's CPU of each interval shared evenly among the runs open
  then — an estimate, as one BEAM serves them all.
  """

  @interval 250
  # Bubblewrap starts in the execution's workspace; the benchmark's own
  # checks name the workspace too, but not through --chdir.
  @execution ~r{--chdir\x00[^\x00]*(executions/[^/]+/[^/]+/\d+)/project/}

  @spec start() :: pid
  def start do
    beam = System.pid()
    spawn_link(fn -> loop(beam, ticks(beam), %{beam: [], processes: %{}}) end)
  end

  @spec stop(pid) :: map
  def stop(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:samples, samples} -> samples
    end
  end

  defp loop(beam, last, acc) do
    receive do
      {:stop, from} -> send(from, {:samples, finish(acc)})
    after
      @interval ->
        now = DateTime.utc_now()
        ticks = ticks(beam)
        children = sandboxed(beam)

        sample = %{
          "at" => DateTime.to_iso8601(now),
          "cpu_percent" =>
            Float.round((ticks - last) / clock_ticks() / (@interval / 1000) * 100, 1),
          "rss_mb" => rss(beam),
          "children_rss_mb" =>
            children |> Enum.map(& &1.rss_mb) |> Enum.reduce(0.0, &+/2) |> Float.round(1)
        }

        processes =
          Enum.reduce(children, acc.processes, fn child, seen ->
            Map.update(
              seen,
              child.pid,
              %{
                "execution" => child.execution,
                "first_at" => sample["at"],
                "cpu_s" => child.cpu_s,
                "peak_rss_mb" => child.rss_mb
              },
              &%{
                &1
                | "cpu_s" => max(&1["cpu_s"], child.cpu_s),
                  "peak_rss_mb" => max(&1["peak_rss_mb"], child.rss_mb)
              }
            )
          end)

        loop(beam, ticks, %{beam: [sample | acc.beam], processes: processes})
    end
  end

  defp finish(acc),
    do: %{"beam" => Enum.reverse(acc.beam), "processes" => Map.values(acc.processes)}

  # The BEAM's descendants that belong to an execution: a process whose
  # command line names an execution's workspace, and what it starts, which
  # inherits it. The BEAM's own helpers belong to none.
  defp sandboxed(beam) do
    parent =
      for entry <- File.ls!("/proc"),
          Integer.parse(entry) != :error,
          {:ok, stat} <- [File.read("/proc/#{entry}/stat")],
          into: %{},
          do: {entry, stat |> String.split(")") |> List.last() |> String.split() |> Enum.at(1)}

    parent
    |> Map.keys()
    |> Enum.flat_map(fn pid ->
      with true <- descends?(pid, beam, parent),
           execution when is_binary(execution) <- execution(pid, beam, parent) do
        [%{pid: pid, execution: execution, cpu_s: ticks(pid) / clock_ticks(), rss_mb: rss(pid)}]
      else
        _other -> []
      end
    end)
  end

  defp descends?(pid, beam, parent) do
    case parent[pid] do
      nil -> false
      ^beam -> true
      "0" -> false
      up -> descends?(up, beam, parent)
    end
  end

  defp execution(pid, beam, parent) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} ->
        case Regex.run(@execution, cmdline) do
          [_, execution] ->
            execution

          nil ->
            if parent[pid] in [nil, beam], do: nil, else: execution(parent[pid], beam, parent)
        end

      {:error, _gone} ->
        nil
    end
  end

  defp ticks(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        fields = stat |> String.split(")") |> List.last() |> String.split()
        String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12))

      {:error, _gone} ->
        0
    end
  end

  defp rss(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} ->
        case Regex.run(~r/VmRSS:\s+(\d+)/, status) do
          [_, kb] -> Float.round(String.to_integer(kb) / 1024, 1)
          nil -> 0.0
        end

      {:error, _gone} ->
        0.0
    end
  end

  defp clock_ticks, do: 100

  @doc """
  The resources of the agents of `executions` (with their runs' times):
  for each agent, the BEAM CPU seconds attributed to its runs, its
  sandboxed processes' CPU seconds and their peak memory.
  """
  @spec by_agent(map, [map]) :: map
  def by_agent(samples, executions) do
    runs =
      for execution <- executions,
          run <- execution["runs"],
          run["started_at"],
          do: Map.put(run, "execution", execution_dir(execution))

    beam =
      samples["beam"]
      |> Enum.reduce(%{}, fn sample, acc ->
        open = Enum.filter(runs, &open?(&1, sample["at"]))
        share = sample["cpu_percent"] / 100 * (@interval / 1000) / max(length(open), 1)
        Enum.reduce(open, acc, &Map.update(&2, &1["agent"], share, fn s -> s + share end))
      end)

    sandbox =
      Enum.reduce(samples["processes"], %{}, fn process, acc ->
        owner =
          runs
          |> Enum.filter(
            &(&1["execution"] == process["execution"] and &1["started_at"] <= process["first_at"])
          )
          |> Enum.max_by(& &1["started_at"], fn -> nil end)

        case owner do
          nil ->
            acc

          run ->
            Map.update(acc, run["agent"], {process["cpu_s"], process["peak_rss_mb"]}, fn {cpu,
                                                                                          rss} ->
              {cpu + process["cpu_s"], max(rss, process["peak_rss_mb"])}
            end)
        end
      end)

    agents = Enum.uniq(Map.keys(beam) ++ Map.keys(sandbox))

    Map.new(agents, fn agent ->
      {cpu, rss} = Map.get(sandbox, agent, {0.0, 0.0})

      {agent,
       %{
         "beam_cpu_s" => Float.round(Map.get(beam, agent, 0.0), 1),
         "sandbox_cpu_s" => Float.round(cpu, 1),
         "sandbox_peak_rss_mb" => rss
       }}
    end)
  end

  @doc "The BEAM's CPU (percent of one core) and memory over the run: median and peak."
  @spec overall(map) :: map
  def overall(%{"beam" => []}), do: %{}

  def overall(%{"beam" => beam}) do
    cpu = beam |> Enum.map(& &1["cpu_percent"]) |> Enum.sort()
    rss = Enum.map(beam, &(&1["rss_mb"] + &1["children_rss_mb"]))

    %{
      "cpu_percent_median" => Enum.at(cpu, div(length(cpu), 2)),
      "cpu_percent_peak" => List.last(cpu),
      "rss_mb_peak" => Float.round(Enum.max(rss), 1)
    }
  end

  defp execution_dir(execution),
    do:
      "executions/#{String.replace(execution["task"], "/", "__")}/#{execution["configuration"]}/#{execution["repetition"]}"

  defp open?(run, at),
    do: run["started_at"] <= at and (run["finished_at"] == nil or at <= run["finished_at"])
end
