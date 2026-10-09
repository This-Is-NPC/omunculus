defmodule EquivalentExchange.Runner do
  @moduledoc """
  Runs the suite and writes what happened into a result folder of its own,
  `eval/results/<time>-<label>/`: a `manifest.json` (when, the commit, the
  model, the configurations, the repetitions and the tasks) and, for each
  task × configuration × repetition, `executions/<task>/<configuration>/<n>/`
  with the project it ran in (its store and final workspace), the events it
  recorded (`events.jsonl`) and `execution.json`: how it ended, the last
  words to the person, the check's verdict, the requests and how they were
  answered, the grants, the runs and tool calls, the usage the provider
  reported, how long it took, the catalog's groups, what the decider says
  of it (`EquivalentExchange.Judge`) and its score
  (`EquivalentExchange.Score`). The manifest says how far the decider was
  trusted on the hand-written reports when the run began.

  `jobs` executions run at once, each in a project of its own. An execution
  builds its project (`EquivalentExchange.Project`), sends the
  instruction through the omunculus CLI, which returns once every run it
  opened has finished, then plays the person: each request waiting on a
  human gets the task's answer for what it asks — grant when the task
  grants it all, by name or by a group holding it, deny otherwise; a path or
  directory inside the workspace asks for `sandbox.write` — and
  the runs that answer opens are
  followed the same way, a few rounds at most. A request offering only
  retry or cancel is left waiting: the model stopped without a report.
  """

  alias EquivalentExchange.{Judge, Project, Score, Task}
  alias Omunculus.CLI
  alias Omunculus.Store.Query

  @eval Path.expand("..", __DIR__)
  @rounds 6

  @spec run(keyword) :: {:ok, String.t()}
  def run(options) do
    model = Keyword.get(options, :model, "luna")
    k = Keyword.get(options, :k, 1)
    started = DateTime.utc_now()
    label = Keyword.get(options, :label, model)

    folder =
      Path.join([@eval, "results", Calendar.strftime(started, "%Y%m%d-%H%M%S") <> "-" <> label])

    tasks = Task.all() |> Enum.filter(&wanted?(&1.id, Keyword.get_values(options, :task)))
    configurations = Keyword.get_values(options, :configuration)

    plan =
      for task <- tasks,
          configuration <- task.configurations,
          configurations == [] or configuration in configurations,
          n <- 1..k,
          do: {task, configuration, n}

    File.mkdir_p!(folder)

    write_json(Path.join(folder, "manifest.json"), %{
      started_at: started,
      label: label,
      commit: commit(),
      model: model,
      repetitions: k,
      configurations: plan |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      tasks: Enum.map(tasks, & &1.id),
      executions: length(plan),
      timeout_s: Keyword.get(options, :timeout, 600),
      jobs: Keyword.get(options, :jobs, 1),
      judge: judge_trust()
    })

    # Executions share nothing — each has its own project — so `jobs` of them
    # run at once; a line is printed as each one ends.
    jobs = Keyword.get(options, :jobs, 1)
    timeout = Keyword.get(options, :timeout, 600)

    plan
    |> Elixir.Task.async_stream(
      fn {task, configuration, n} ->
        {task, configuration, n, execute(folder, task, configuration, n, model, timeout)}
      end,
      max_concurrency: jobs,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.with_index(1)
    |> Enum.each(fn {{:ok, {task, configuration, n, execution}}, at} ->
      IO.puts(
        "[#{at}/#{length(plan)}] #{task.id} · #{configuration} · #{n} · #{execution["outcome"]} · " <>
          "#{if execution["score"].passed, do: "passed", else: "failed"} · #{execution["duration_ms"]} ms"
      )
    end)

    EquivalentExchange.Report.write(folder)
    {:ok, folder}
  end

  defp wanted?(_id, []), do: true
  defp wanted?(id, filters), do: Enum.any?(filters, &String.contains?(id, &1))

  defp execute(folder, task, configuration, n, model, timeout_s) do
    dir =
      Path.join([
        folder,
        "executions",
        String.replace(task.id, "/", "__"),
        configuration,
        Integer.to_string(n)
      ])

    project = Path.join(dir, "project")
    File.mkdir_p!(project)

    {:ok, config_path} =
      Project.build(project, configuration, model, Path.join(task.dir, "workspace"))

    groups = groups(config_path)
    started = System.monotonic_time(:millisecond)

    {status, answers} =
      within(timeout_s * 1000, fn ->
        with {:ok, _said} <- CLI.run(["--config", config_path, "send", task.instruction], project) do
          {:ok, play_person(config_path, project, task, groups, [], @rounds)}
        end
      end)

    duration = System.monotonic_time(:millisecond) - started
    facts = facts(project)
    outcome = outcome(facts, status)
    workspace = Path.join(project, "workspace")
    report = report(facts)

    {passed, said} =
      Task.check(task, workspace, %{
        outcome: outcome,
        report: report,
        configuration: configuration
      })

    File.write!(
      Path.join(dir, "events.jsonl"),
      Enum.map_join(facts.events, "\n", &Jason.encode!/1)
    )

    execution = %{
      task: task.id,
      scenario: task.scenario,
      critical: task.critical,
      configuration: configuration,
      repetition: n,
      model: model,
      outcome: outcome,
      expected: Task.outcomes(task, configuration),
      report: report,
      check: %{passed: passed, said: said},
      error: error(status),
      requests: requests(facts, answers, project),
      grants: grants(facts, project),
      runs: Enum.map(facts.runs, &%{agent: &1.agent, depth: &1.depth, via: &1.via}),
      tool_calls: tool_calls(facts),
      usage: usage(facts),
      duration_ms: duration,
      needs: task.needs,
      forbidden: task.forbidden,
      groups: groups
    }

    execution = assess(execution, task, workspace)
    write_json(Path.join(dir, "execution.json"), execution)
    execution
  end

  @doc """
  An execution of `task` that left `workspace`, with what the decider says
  of it and its score.
  """
  @spec assess(map, %Task{}, String.t()) :: map
  def assess(execution, task, workspace) do
    execution =
      execution
      |> Map.put("judgments", Judge.judge(task, execution["report"] || "", workspace))
      |> Jason.encode!()
      |> Jason.decode!()

    Map.put(execution, "score", Score.score(execution))
  end

  @doc """
  The execution recorded at `path`, of `task`, assessed again: its last
  words and usage read again from the store it ran in, its check run again
  on the workspace it left, then judged and scored with today's questions.
  """
  @spec reassess(String.t(), %Task{}) :: map
  def reassess(path, task) do
    project = Path.join(Path.dirname(path), "project")
    workspace = Path.join(project, "workspace")
    facts = facts(project)
    execution = path |> File.read!() |> Jason.decode!()
    report = report(facts)

    {passed, said} =
      Task.check(task, workspace, %{
        outcome: execution["outcome"],
        report: report,
        configuration: execution["configuration"]
      })

    execution
    |> Map.merge(%{
      "report" => report,
      "check" => %{"passed" => passed, "said" => said},
      "usage" => usage(facts)
    })
    |> assess(task, workspace)
  end

  @doc "How the decider did on the hand-written reports, for a manifest."
  @spec judge_trust() :: map
  def judge_trust do
    {right, asked} = Judge.trust()
    %{right: right, asked: asked}
  end

  # The person: answers what waits on them, then follows the runs that opens.
  defp play_person(_config_path, _project, _task, _groups, answers, 0), do: answers

  defp play_person(config_path, project, task, groups, answers, rounds) do
    case waiting_on_person(project) do
      [] ->
        answers

      waiting ->
        given =
          for request <- waiting,
              option = choose(task, groups, request, project),
              option != nil do
            {:ok, _said} =
              CLI.run(
                [
                  "--config",
                  config_path,
                  "reply",
                  "--request_id",
                  request.id,
                  "--option",
                  option,
                  "--body",
                  "simulated person: #{option}"
                ],
                project
              )

            %{request: request.id, option: option}
          end

        if given == [],
          do: answers,
          else: play_person(config_path, project, task, groups, answers ++ given, rounds - 1)
    end
  end

  defp waiting_on_person(project) do
    with_store(project, fn conn ->
      {:ok, rows} =
        Query.all(
          conn,
          "SELECT id, options FROM requests WHERE status = 'waiting_human' ORDER BY created_at"
        )

      rows
    end)
  end

  # Grant when the task grants everything the request asks, by the name or by
  # a group that holds it; deny otherwise. A grant is temporary when the
  # request offers it, else for the asking agent (a request made without a
  # work offers no temporary one). A request without grant and deny (retry or
  # cancel) is left waiting.
  defp choose(task, groups, request, project) do
    options = Jason.decode!(request.options)
    names = asks(options, project)

    granted? = fn name ->
      Enum.any?([name | groups_of(groups, name)], &(Task.answer(task, &1) == "grant"))
    end

    grant = Enum.find(["grant", "grant_agent"], &Map.has_key?(options, &1))

    cond do
      names != [] and Enum.all?(names, granted?) and grant != nil -> grant
      Map.has_key?(options, "deny") -> "deny"
      true -> nil
    end
  end

  defp groups_of(groups, name), do: for({group, members} <- groups, name in members, do: group)

  defp groups(config_path) do
    {:ok, config} = Omunculus.Config.load(config_path)
    config.tools |> Omunculus.Tool.Catalog.discover() |> Omunculus.Tool.Catalog.groups()
  end

  defp requested(options) do
    for {_option, calls} <- options,
        %{"name" => "grant", "args" => %{"name" => _name} = args} <- calls,
        uniq: true,
        do: Map.take(args, ~w(kind name))
  end

  defp asks(options, project),
    do: options |> requested() |> Enum.map(&subject(&1, project)) |> Enum.uniq()

  # What a grant gives, as the task names it: writing a path or directory
  # inside the workspace is sandbox.write; anything else is its name.
  defp subject(%{"kind" => kind, "name" => name}, project) when kind in ~w(path directory) do
    workspace = Path.join(project, "workspace")
    path = Path.expand(name, workspace)

    if path == workspace or String.starts_with?(path, workspace <> "/"),
      do: "sandbox.write",
      else: name
  end

  defp subject(%{"name" => name}, _project), do: name

  defp facts(project) do
    with_store(project, fn conn ->
      {:ok, events} = Query.all(conn, "SELECT * FROM events ORDER BY rowid")
      {:ok, runs} = Query.all(conn, "SELECT * FROM runs ORDER BY started_at")
      {:ok, works} = Query.all(conn, "SELECT * FROM works ORDER BY created_at")
      {:ok, requests} = Query.all(conn, "SELECT * FROM requests ORDER BY created_at")
      %{events: Enum.map(events, &decode_body/1), runs: runs, works: works, requests: requests}
    end)
  end

  defp decode_body(event) do
    case event.body && Jason.decode(event.body) do
      {:ok, body} -> Map.put(event, :body, body)
      _other -> event
    end
  end

  # How the conversation ended for the person.
  defp outcome(_facts, {:error, :timeout}), do: "timeout"
  defp outcome(_facts, {:error, _reason}), do: "error"

  defp outcome(facts, {:ok, _answers}) do
    root = Enum.find(facts.works, &is_nil(&1.parent_id))
    waiting = Enum.filter(facts.requests, &(&1.status == "waiting_human"))

    broke =
      Enum.any?(
        facts.events,
        &(&1.type == "break" and (is_nil(root) or &1.work_id == root.id or is_nil(&1.work_id)))
      )

    cond do
      root && root.state == "done" -> "done"
      Enum.any?(waiting, &(requested(Jason.decode!(&1.options)) != [])) -> "waiting"
      waiting != [] -> "stalled"
      broke or (root && root.state == "cancelled") -> "break"
      is_nil(root) -> "answer"
      true -> "stalled"
    end
  end

  # The last words to the person: what a depth-0 run said, or the last
  # comment an agent wrote on the root work.
  defp report(facts) do
    root = Enum.find(facts.works, &is_nil(&1.parent_id))
    top = facts.runs |> Enum.filter(&(&1.depth == "0")) |> MapSet.new(& &1.id)

    facts.events
    |> Enum.flat_map(fn event ->
      cond do
        event.type == "model" and MapSet.member?(top, event.run_id) ->
          [said(event.body)]

        event.type == "comment" and root != nil and event.work_id == root.id and
            event.actor_kind == "agent" ->
          [event.body["body"]]

        event.type == "break" and is_map(event.body) and is_binary(event.body["body"]) ->
          [event.body["body"]]

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> List.last() || ""
  end

  defp said(text) when is_binary(text), do: text
  defp said(%{"content" => content}) when is_binary(content), do: content

  defp said(%{"content" => parts}) when is_list(parts),
    do: parts |> Enum.map(&(&1["text"] || "")) |> Enum.join("\n")

  defp said(_body), do: ""

  defp requests(facts, answers, project) do
    Enum.map(facts.requests, fn request ->
      options = Jason.decode!(request.options)

      %{
        id: request.id,
        agent: request.agent,
        depth: Enum.find_value(facts.runs, &(&1.id == request.run_id && &1.depth)),
        arbiter: request.arbiter,
        status: request.status,
        names: options |> requested() |> Enum.map(& &1["name"]) |> Enum.uniq(),
        asks: asks(options, project),
        options: Map.keys(options),
        answered_by_person: Enum.find_value(answers, &(&1.request == request.id && &1.option))
      }
    end)
  end

  defp grants(facts, project) do
    for %{type: "grant"} = event <- facts.events do
      %{
        name: event.body["name"],
        kind: event.body["kind"],
        subject: subject(Map.take(event.body, ~w(kind name)), project),
        by: event.actor_kind,
        agent: event.actor_id,
        work: event.work_id
      }
    end
  end

  defp tool_calls(facts) do
    for %{type: "tool", body: %{"name" => name} = body} = event <- facts.events,
        name != "assemble" do
      %{name: name, ok: body["ok"], via: body["via"], run: event.run_id}
    end
  end

  # What the provider reported of each model call, and of the prompt it
  # served from its cache: overall, on the first call of each run, and by
  # agent.
  defp usage(facts) do
    agents = Map.new(facts.runs, &{&1.id, &1.agent})

    calls =
      for %{type: "model", body: %{"usage" => usage}} = event <- facts.events, is_map(usage) do
        %{run: event.run_id, agent: agents[event.run_id], usage: usage}
      end

    firsts = calls |> Enum.uniq_by(& &1.run) |> Enum.map(& &1.usage)
    usages = Enum.map(calls, & &1.usage)

    %{
      calls: Enum.count(facts.events, &(&1.type == "model")),
      input_tokens: sum(usages, "prompt_tokens"),
      output_tokens: sum(usages, "completion_tokens"),
      cost: sum(usages, "cost"),
      cache: cache(usages),
      first_call_cache: cache(firsts),
      cache_by_agent:
        calls |> Enum.group_by(& &1.agent, & &1.usage) |> Map.new(fn {a, u} -> {a, cache(u)} end)
    }
  end

  defp cache(usages) do
    details = Enum.map(usages, &(&1["prompt_tokens_details"] || %{}))

    %{
      prompt_tokens: sum(usages, "prompt_tokens"),
      cached_tokens: sum(details, "cached_tokens"),
      cache_write_tokens: sum(details, "cache_write_tokens")
    }
  end

  defp sum(maps, key), do: maps |> Enum.map(&(&1[key] || 0)) |> Enum.sum()

  defp error({:error, :timeout}), do: "timeout"
  defp error({:error, reason}), do: CLI.format_error(reason)
  defp error({:ok, _answers}), do: nil

  # Runs `fun` within `ms`; {:error, :timeout} past it.
  defp within(ms, fun) do
    work = Elixir.Task.async(fn -> fun.() end)

    case Elixir.Task.yield(work, ms) || Elixir.Task.shutdown(work, :brutal_kill) do
      {:ok, {:ok, answers}} -> {{:ok, answers}, answers}
      {:ok, {:error, reason}} -> {{:error, reason}, []}
      nil -> {{:error, :timeout}, []}
    end
  end

  defp with_store(project, fun) do
    {:ok, config} = Omunculus.Config.load(Path.join(project, "omunculus.toml"))
    {:ok, opened} = Omunculus.Project.open(config, lock: false)

    try do
      fun.(opened.conn)
    after
      Omunculus.Project.close(opened)
    end
  end

  defp commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp write_json(path, data), do: File.write!(path, Jason.encode!(data, pretty: true))
end
