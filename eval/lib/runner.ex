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
  followed the same way. Free-text questions use the task's simulated person,
  once per received envelope, preserving the conversation and returning linked
  origins to intermediaries for distribution. A finite execution timeout bounds
  the response loop; `infinity` waits until it ends. A request offering only
  retry or cancel is left waiting.

  A task with `[person]` goes on as a conversation: once the runs settle,
  `EquivalentExchange.Person` reads what the agent last said and answers
  what it asks, which is sent as the person's next message, until it asks
  nothing; then each of the task's `follow_ups` is sent the same way. Only
  a finite execution timeout bounds how long it goes on. A task with `deploy`
  publishes to the deploy environment (`EquivalentExchange.Deploy`); what
  production serves for the app it promoted is copied for the check, then
  every app it published is removed.
  """

  alias EquivalentExchange.{
    Deploy,
    Judge,
    Person,
    Project,
    Resources,
    Score,
    Task,
    Requests,
    Usage,
    Deadline
  }

  alias Omunculus.CLI
  alias Omunculus.Store.Query

  @eval Path.expand("..", __DIR__)

  @spec run(keyword) :: {:ok, String.t()}
  def run(options) do
    case Keyword.fetch(options, :resume) do
      {:ok, folder} ->
        unless Keyword.keys(options) == [:resume],
          do:
            raise(
              ArgumentError,
              "--resume uses the saved manifest; other run options are refused"
            )

        resume(Path.expand(folder))

      :error ->
        fresh(options)
    end
  end

  defp fresh(options) do
    model =
      Keyword.get_lazy(options, :model, fn ->
        raise ArgumentError, "--model names the preset's model the run uses"
      end)

    code_mode = Keyword.get(options, :code_mode, false)
    overlay = if options[:overlay], do: Path.expand(options[:overlay])

    agent_models =
      options
      |> Keyword.get_values(:agent_model)
      |> Map.new(fn value ->
        case String.split(value, "=", parts: 2) do
          [agent, model] when agent != "" and model != "" -> {agent, model}
          _ -> raise ArgumentError, "--agent-model expects agent=model, got: #{value}"
        end
      end)

    k = Keyword.get(options, :k, 1)
    timeout = options |> Keyword.get(:timeout, "600") |> Deadline.parse()
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

    against = against(options)

    if Enum.any?(plan, fn {task, _configuration, _n} -> task.deploy end) do
      with {:error, reason} <- Deploy.environment(), do: raise(reason)
    end

    File.mkdir_p!(folder)

    write_json(Path.join(folder, "manifest.json"), %{
      started_at: started,
      label: label,
      commit: commit(),
      model: model,
      agent_models: agent_models,
      code_mode: code_mode,
      overlay: overlay,
      repetitions: k,
      configurations: plan |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      tasks: Enum.map(tasks, & &1.id),
      executions: length(plan),
      timeout_s: timeout,
      jobs: Keyword.get(options, :jobs, 1),
      judge: judge_trust(),
      against: against
    })

    # Executions share nothing — each has its own project — so `jobs` of them
    # run at once; a line is printed as each one ends.
    jobs = Keyword.get(options, :jobs, 1)
    plan = Enum.map(plan, fn {task, configuration, n} -> {task, configuration, n, false} end)
    run_plan(folder, plan, {model, code_mode, agent_models, overlay}, timeout, jobs)
  end

  defp resume(folder) do
    manifest_path = Path.join(folder, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    tasks = Map.new(Task.all(), &{&1.id, &1})

    plan =
      for id <- manifest["tasks"],
          configuration <- manifest["configurations"],
          configuration in Map.fetch!(tasks, id).configurations,
          n <- 1..manifest["repetitions"],
          not File.exists?(
            Path.join(execution_dir(folder, id, configuration, n), "execution.json")
          ),
          do: {Map.fetch!(tasks, id), configuration, n}

    # An execution stopped before its store held anything starts over; one
    # that began continues from its store.
    plan =
      for {task, configuration, n} <- plan do
        dir = execution_dir(folder, task.id, configuration, n)

        case begun(dir) do
          {:ok, store} ->
            {:ok, lock} = Omunculus.Store.Lock.acquire(store)
            Omunculus.Store.Lock.release(lock)
            {task, configuration, n, true}

          :none ->
            File.rm_rf!(dir)
            {task, configuration, n, false}
        end
      end

    if Enum.any?(plan, fn {task, _configuration, _n, _resume?} -> task.deploy end) do
      with {:error, reason} <- Deploy.environment(), do: raise(reason)
    end

    manifest =
      Map.update(
        manifest,
        "resumptions",
        [resumption()],
        fn prior ->
          prior ++ [resumption()]
        end
      )

    write_json(manifest_path, manifest)

    run_plan(
      folder,
      plan,
      {manifest["model"], manifest["code_mode"], manifest["agent_models"] || %{},
       manifest["overlay"]},
      Deadline.parse(to_string(manifest["timeout_s"])),
      manifest["jobs"]
    )
  end

  defp begun(dir) do
    with {:ok, config} <- Omunculus.Config.load(Path.join([dir, "project", "omunculus.toml"])),
         true <- File.regular?(config.store.path) do
      {:ok, config.store.path}
    else
      _not_begun -> :none
    end
  end

  defp run_plan(folder, plan, models, timeout, jobs) do
    sampler = Resources.start()

    plan
    |> Elixir.Task.async_stream(
      fn {task, configuration, n, resume?} ->
        {task, configuration, n,
         execute(folder, task, configuration, n, models, timeout, resume?)}
      end,
      max_concurrency: jobs,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.with_index(1)
    |> Enum.each(fn {{:ok, {task, configuration, n, execution}}, at} ->
      IO.puts(
        "[#{at}/#{length(plan)}] #{task.id} · #{configuration} · #{n} · #{execution["outcome"]} · " <>
          "#{passed(execution["score"].passed)} · #{execution["duration_ms"]} ms" <>
          if(execution["score"].judge_unavailable,
            do: " · decider unavailable: #{execution["score"].judge_unavailable}",
            else: ""
          )
      )
    end)

    samples = Resources.stop(sampler)
    resource_path = Path.join(folder, "resources.json")

    # A resumed run adds its samples to those of the runs before it.
    if File.exists?(resource_path) do
      previous = resource_path |> File.read!() |> Jason.decode!()
      samples = Map.merge(previous, samples, fn _key, old, new -> old ++ new end)
      write_json(resource_path, samples)
    else
      write_json(resource_path, samples)
    end

    EquivalentExchange.Report.write(folder)
    {:ok, folder}
  end

  defp passed(true), do: "passed"
  defp passed(false), do: "failed"
  defp passed(nil), do: "unjudged"

  defp wanted?(_id, []), do: true
  defp wanted?(id, filters), do: Enum.any?(filters, &String.contains?(id, &1))

  defp execution_dir(folder, task_id, configuration, n) do
    Path.join([
      folder,
      "executions",
      String.replace(task_id, "/", "__"),
      configuration,
      to_string(n)
    ])
  end

  defp execute(
         folder,
         task,
         configuration,
         n,
         {model, code_mode, agent_models, overlay},
         timeout_s,
         resume?
       ) do
    dir = execution_dir(folder, task.id, configuration, n)

    project = Path.join(dir, "project")
    File.mkdir_p!(project)

    config_path = Path.join(project, "omunculus.toml")

    unless resume? do
      {:ok, ^config_path} =
        Project.build(
          project,
          configuration,
          {model, code_mode},
          Path.join(task.dir, "workspace"),
          agent_models,
          overlay
        )
    end

    groups = groups(config_path)
    workspace = Path.join(project, "workspace")
    # What truly changed, told apart the way the harness tells each call's.
    truth = Path.join(project, "truth")
    {before, elapsed} = execution_start(dir, project, truth, workspace, resume?)
    {:ok, settings} = Project.configuration(configuration, overlay)
    entry_agent = get_in(settings, ["eval", "entry_agent"])
    person = %{facts: task.person && task.person["facts"], task: task, entry_agent: entry_agent}
    instruction = task.instruction
    started = System.monotonic_time(:millisecond)

    {status, played} =
      Deadline.run(
        timeout_s,
        fn ->
          played =
            if resume?,
              do: Person.restore(facts(project), task, &last_words/2),
              else: %{
                answers: [],
                conversation: [{"person", instruction}],
                follow_ups: (task.person && task.person["follow_ups"]) || []
              }

          opening = if resume?, do: ["overview"], else: send_arguments(instruction, entry_agent)

          with {:ok, _said} <- CLI.run(["--config", config_path | opening], project),
               {:ok, played} <-
                 play_person(config_path, project, task, groups, played) do
            converse(
              {config_path, project, groups, person},
              played,
              played.follow_ups
            )
          end
        end,
        elapsed
      )

    answers = (played && played.answers) || []
    conversation = Enum.map((played && played.conversation) || [], &Tuple.to_list/1)
    duration = elapsed + System.monotonic_time(:millisecond) - started
    facts = facts(project)

    if task.deploy do
      case Deploy.published(facts.events) do
        [] ->
          :ok

        [app | _others] = apps ->
          Deploy.mirror(app, Path.join([dir, "prod", "site"]))
          Enum.each(apps, &Deploy.destroy/1)
      end
    end

    outcome = outcome(facts, status)
    report = report(facts)
    {:ok, after_} = Omunculus.Changes.snapshot(truth, workspace, [])
    {:ok, changed} = Omunculus.Changes.files(truth, before, after_)

    {passed, said, files} =
      check(task, workspace, facts, %{
        outcome: outcome,
        configuration: configuration,
        conversation: conversation,
        dir: dir
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
      agent_models: agent_models,
      outcome: outcome,
      expected: Task.outcomes(task, configuration),
      expected_report: task.expect["report"],
      report: report,
      conversation: conversation,
      check: %{passed: passed, said: said, files: files},
      error: error(status),
      requests: requests(facts, answers, project),
      grants: grants(facts),
      runs:
        Enum.map(
          facts.runs,
          &%{
            agent: &1.agent,
            depth: &1.depth,
            via: &1.via,
            started_at: &1.started_at,
            finished_at: &1.finished_at
          }
        ),
      tool_calls: tool_calls(facts),
      changed: Enum.map(changed, & &1["path"]),
      sent_back: sent_back(facts),
      works: works(facts),
      usage: usage(facts, project),
      duration_ms: duration,
      needs: task.needs,
      forbidden: task.forbidden,
      uses: task.uses,
      groups: groups
    }

    execution = assess(execution, task, workspace)
    write_json(Path.join(dir, "execution.json"), execution)
    execution
  end

  defp execution_start(dir, project, truth, workspace, resume?) do
    checkpoint = Path.join(dir, "continuation.json")
    previous = if File.exists?(checkpoint), do: checkpoint |> File.read!() |> Jason.decode!()

    {before, elapsed} =
      if resume? do
        facts = facts(project)

        last =
          facts.events |> List.last() |> Map.fetch!(:at) |> DateTime.from_iso8601() |> elem(1)

        first =
          if previous,
            do: previous["segment_started_at"],
            else: facts.events |> hd() |> Map.fetch!(:at)

        {:ok, first, _} = DateTime.from_iso8601(first)

        elapsed =
          ((previous && previous["elapsed_ms"]) || 0) +
            max(DateTime.diff(last, first, :millisecond), 0)

        before =
          if previous do
            previous["before"]
          else
            index = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)

            {:ok, tree} =
              Omunculus.Git.run(["--git-dir", truth, "write-tree"], project, [
                {"GIT_INDEX_FILE", Path.join(truth, "index-" <> index)}
              ])

            String.trim(tree)
          end

        {before, elapsed}
      else
        {:ok, before} = Omunculus.Changes.snapshot(truth, workspace, [])
        {before, 0}
      end

    write_json(checkpoint <> ".tmp", %{
      before: before,
      elapsed_ms: elapsed,
      segment_started_at: DateTime.utc_now()
    })

    File.rename!(checkpoint <> ".tmp", checkpoint)

    {before, elapsed}
  end

  @doc """
  An execution of `task` that left `workspace`, with what the decider says
  of it and its score.
  """
  @spec assess(map, %Task{}, String.t()) :: map
  def assess(execution, task, workspace) do
    # As JSON first: an execution just built has atom keys, one read from disk string keys.
    execution = execution |> Jason.encode!() |> Jason.decode!()

    execution =
      Map.put(execution, "judgments", Judge.judge(task, execution["report"], workspace))

    Map.put(execution, "score", Score.score(execution))
  end

  @doc """
  The execution recorded at `path`, of `task`, assessed again: its last
  words, grants and usage read again from the store it ran in, its check run again
  on the workspace it left, then judged and scored with today's questions.
  """
  @spec reassess(String.t(), %Task{}) :: map
  def reassess(path, task) do
    project = Path.join(Path.dirname(path), "project")
    workspace = Path.join(project, "workspace")
    facts = facts(project)
    execution = path |> File.read!() |> Jason.decode!()
    report = report(facts)

    {passed, said, files} =
      check(task, workspace, facts, %{
        outcome: execution["outcome"],
        configuration: execution["configuration"],
        conversation: execution["conversation"] || [],
        dir: Path.dirname(path)
      })

    execution
    |> Map.merge(%{
      "report" => report,
      "expected_report" => task.expect["report"],
      "check" => %{"passed" => passed, "said" => said, "files" => files},
      "grants" => grants(facts),
      "usage" => usage(facts, project)
    })
    |> assess(task, workspace)
  end

  @doc """
  The result folder `--against` names, which the run is compared with;
  nil without one. A folder without a manifest is refused before anything
  runs.
  """
  @spec against(keyword) :: String.t() | nil
  def against(options) do
    case Keyword.get(options, :against) do
      nil ->
        nil

      path ->
        folder = Path.expand(path)

        unless File.regular?(Path.join(folder, "manifest.json")),
          do: raise(ArgumentError, "--against #{path}: no result folder there")

        folder
    end
  end

  @doc "How the decider did on the hand-written reports, for a manifest."
  @spec judge_trust() :: map
  def judge_trust do
    {right, asked} = Judge.trust()
    %{right: right, asked: asked}
  end

  # Each received envelope is one client message, even when its answer
  # records several named decisions. Text answers return origins for distribution.
  defp play_person(config_path, project, task, groups, played) do
    waiting_on_person(project)
    |> Enum.reduce_while({:ok, played, 0}, fn request, {:ok, played, count} ->
      conversation = played.conversation ++ [{"agent", request.reason}]

      reply = fn _question ->
        if task.person,
          do: Person.reply(task.person["facts"], conversation),
          else: {:ok, :nothing}
      end

      with {:ok, answer} <- Requests.answer(task, groups, request, project, reply) do
        if is_nil(answer) do
          {:cont, {:ok, played, count}}
        else
          case CLI.run(Requests.arguments(config_path, request.id, answer), project) do
            {:ok, _said} ->
              {:cont,
               {:ok,
                %{
                  played
                  | answers: played.answers ++ Requests.answers(request, answer),
                    conversation: conversation ++ [{"person", answer["body"]}]
                }, count + 1}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, played, 0} -> {:ok, played}
      {:ok, played, _count} -> play_person(config_path, project, task, groups, played)
      error -> error
    end
  end

  # Once the runs settle, the person answers what the agent last said, or,
  # asked nothing, sends their next follow-up.
  # Last words the agent already said are not said again: it asked nothing.
  defp converse({config_path, project, groups, person} = at, played, follow_ups) do
    facts = facts(project)
    said = last_words(facts, facts.events)

    new? =
      String.trim(said) != "" and
        said not in for({"agent", earlier} <- played.conversation, do: earlier)

    conversation =
      if new?, do: played.conversation ++ [{"agent", said}], else: played.conversation

    reply =
      if person.facts && new?,
        do: Person.reply(person.facts, conversation),
        else: {:ok, :nothing}

    message =
      case {reply, follow_ups} do
        {{:ok, :nothing}, []} -> :done
        {{:ok, :nothing}, [next | rest]} -> {:ok, next, rest}
        {{:ok, text}, _follow_ups} -> {:ok, text, follow_ups}
        {{:error, _reason} = error, _follow_ups} -> error
      end

    with {:ok, text, follow_ups} <- message,
         {:ok, _said} <-
           CLI.run(["--config", config_path | send_arguments(text, person.entry_agent)], project),
         {:ok, played} <-
           play_person(config_path, project, person.task, groups, %{
             played
             | conversation: conversation ++ [{"person", text}]
           }) do
      converse(at, played, follow_ups)
    else
      :done -> {:ok, %{played | conversation: conversation}}
      error -> error
    end
  end

  defp send_arguments(message, nil), do: ["send", message]
  defp send_arguments(message, agent), do: ["send", message, "--agent", agent]

  # The task's check on what the execution left: its workspace, its works,
  # what was said and, for a task that publishes, the published copy.
  defp check(task, workspace, facts, execution) do
    published = Path.expand(Path.join([execution.dir, "prod", "site"]))

    Task.check(task, workspace, %{
      outcome: execution.outcome,
      report: report(facts),
      configuration: execution.configuration,
      works: roots(facts),
      team: team(facts),
      conversation: execution.conversation,
      first_run_made_work: first_run_made_work(facts),
      published: if(task.deploy, do: published)
    })
  end

  # Whether the person's first message became a work at once.
  defp first_run_made_work(facts) do
    case Enum.find(facts.runs, &(&1.depth == "0")) do
      nil -> false
      first -> Enum.any?(facts.events, &(&1.run_id == first.id and &1.type == "work"))
    end
  end

  # Every work, with who it went to: which agents of the teams worked.
  defp team(facts) do
    for work <- facts.works,
        do: %{
          id: work.id,
          parent_id: work.parent_id,
          title: work.title,
          goal: work.goal,
          assignee: work.assignee,
          state: work.state
        }
  end

  # The root works, as the person's requests became them.
  defp roots(facts) do
    for work <- facts.works,
        is_nil(work.parent_id),
        do: %{id: work.id, title: work.title, goal: work.goal, state: work.state}
  end

  defp waiting_on_person(project) do
    with_store(project, fn conn ->
      {:ok, rows} =
        Query.all(
          conn,
          "SELECT id, options FROM requests WHERE status = 'pending' AND json_extract(arbiter, '$.kind') = 'human' ORDER BY created_at"
        )

      request_views(conn, rows)
    end)
  end

  defp groups(config_path) do
    {:ok, config} = Omunculus.Config.load(config_path)
    config.tools |> Omunculus.Tool.Catalog.discover() |> Omunculus.Tool.Catalog.groups()
  end

  defp facts(project) do
    with_store(project, fn conn ->
      {:ok, events} = Query.all(conn, "SELECT * FROM events ORDER BY rowid")
      {:ok, runs} = Query.all(conn, "SELECT * FROM runs ORDER BY started_at")
      {:ok, works} = Query.all(conn, "SELECT * FROM works ORDER BY created_at")
      {:ok, rows} = Query.all(conn, "SELECT id FROM requests ORDER BY created_at")

      requests =
        request_views(conn, rows)

      %{events: Enum.map(events, &decode_body/1), runs: runs, works: works, requests: requests}
    end)
  end

  defp request_views(conn, rows) do
    Enum.map(rows, fn row ->
      {:ok, request} = Omunculus.Store.view(conn, "request", row.id)
      request
    end)
  end

  @doc "An event with its body decoded from JSON; one with no body or another text as it is."
  @spec decode_body(map) :: map
  def decode_body(event) do
    case event.body && Jason.decode(event.body) do
      {:ok, body} -> Map.put(event, :body, body)
      _other -> event
    end
  end

  # How the conversation ended for the person.
  defp outcome(_facts, {:error, :timeout}), do: "timeout"
  defp outcome(_facts, {:error, _reason}), do: "error"

  defp outcome(facts, {:ok, _answers}) do
    root = last_root(facts)

    waiting =
      Enum.filter(
        facts.requests,
        &(&1.status == "pending" and Jason.decode!(&1.arbiter)["kind"] == "human")
      )

    broke =
      Enum.any?(
        facts.events,
        &(&1.type == "break" and (is_nil(root) or &1.work_id == root.id or is_nil(&1.work_id)))
      )

    cond do
      root && root.state == "done" -> "done"
      Enum.any?(waiting, &(Requests.requirements(&1) != [])) -> "waiting"
      waiting != [] -> "stalled"
      # It waits for the person's next message: its agent answered them.
      root && root.state == "waiting" && root.waiting == "message" -> "answer"
      broke or (root && root.state == "cancelled") -> "break"
      # Open and waiting on no one: its agent answered and waits for the person.
      is_nil(root) or root.state == "open" -> "answer"
      true -> "stalled"
    end
  end

  # The report judged: the last words up to the root work's close, so what
  # the person and the agent say after it is not taken for the report.
  defp report(facts) do
    root = last_root(facts)

    closed =
      Enum.find_index(Enum.reverse(facts.events), fn event ->
        root != nil and event.work_id == root.id and event.type == "continue" and
          is_map(event.body) and is_nil(event.body["to"])
      end)

    events =
      if closed, do: Enum.drop(facts.events, -closed), else: facts.events

    last_words(facts, events)
  end

  # The conversation's latest root work: a later request of the person's
  # may open one of its own.
  defp last_root(facts), do: facts.works |> Enum.filter(&is_nil(&1.parent_id)) |> List.last()

  # The last words to the person: what a depth-0 run said in a reply that
  # called no tool, or the last comment an agent wrote on a root work.
  defp last_words(facts, events) do
    roots = for work <- facts.works, is_nil(work.parent_id), into: MapSet.new(), do: work.id
    top = facts.runs |> Enum.filter(&(&1.depth == "0")) |> MapSet.new(& &1.id)

    events
    |> Enum.flat_map(fn event ->
      cond do
        event.type == "model" and MapSet.member?(top, event.run_id) ->
          [Omunculus.Tools.Record.answer(event.body)]

        event.type == "comment" and MapSet.member?(roots, event.work_id) and
            event.actor_kind == "agent" ->
          [event.body["body"]]

        event.type == "break" and is_map(event.body) and is_binary(event.body["body"]) ->
          [event.body["body"]]

        true ->
          []
      end
    end)
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> List.last() || ""
  end

  defp requests(facts, answers, project) do
    Enum.map(facts.requests, fn request ->
      options = Jason.decode!(request.options)

      %{
        id: request.id,
        requester: Jason.decode!(request.requester),
        depth: Enum.find_value(facts.runs, &(&1.id == request.run_id && &1.depth)),
        arbiter: Jason.decode!(request.arbiter),
        status: request.status,
        names: options |> Requests.requested() |> Enum.map(& &1["name"]) |> Enum.uniq(),
        asks: Requests.asks(options, project),
        options: Map.keys(options),
        answered_by_person: Enum.find_value(answers, &(&1.request == request.id && &1.option))
      }
    end)
  end

  # A grant is what it names: a path or directory grant gives no means to
  # write, which only sandbox.write does.
  defp grants(facts) do
    for %{type: "grant"} = event <- facts.events do
      %{
        name: event.body["name"],
        kind: event.body["kind"],
        subject: event.body["name"],
        by: event.actor_kind,
        agent: event.actor_id,
        work: event.work_id
      }
    end
  end

  defp tool_calls(facts) do
    for %{type: "tool", body: %{"name" => name} = body} = event <- facts.events,
        name != "assemble" do
      %{
        name: name,
        ok: body["ok"],
        via: body["via"],
        run: event.run_id,
        changed:
          for(
            file <- get_in(body, ["changes", "files"]) || [],
            do: Map.take(file, ~w(path op added))
          ),
        command: if(name == "bash", do: get_in(body, ["args", "command"]))
      }
    end
  end

  # How often a run sent work back down — work or reopen — after a deeper
  # run had called it done: a supervisor not taking a child's word for it.
  defp sent_back(facts) do
    depth = Map.new(facts.runs, &{&1.id, String.to_integer(&1.depth)})

    facts.events
    |> Enum.filter(&match?(%{type: "tool", body: %{"name" => _}}, &1))
    |> Enum.reject(&Map.has_key?(&1.body, "via"))
    |> Enum.reduce({0, nil}, fn event, {count, done_at} ->
      at = depth[event.run_id]

      case {event.body["name"], event.body["ok"]} do
        {"done", true} ->
          {count, max(done_at || 0, at)}

        {name, _ok} when name in ~w(work reopen) and done_at != nil and at < done_at ->
          {count + 1, nil}

        _other ->
          {count, done_at}
      end
    end)
    |> elem(0)
  end

  # The works the conversation made, each its depth and how it ended.
  defp works(facts) do
    by_id = Map.new(facts.works, &{&1.id, &1})

    for work <- facts.works,
        do: %{depth: work_depth(work, by_id), state: work.state, assignee: work.assignee}
  end

  defp work_depth(%{parent_id: nil}, _by_id), do: 0

  defp work_depth(%{parent_id: parent}, by_id),
    do: 1 + work_depth(Map.fetch!(by_id, parent), by_id)

  defp usage(facts, project) do
    {:ok, config} = Omunculus.Config.load(Path.join(project, "omunculus.toml"))
    prices = @eval |> Path.join("prices.toml") |> Toml.decode_file!()
    Usage.summarize(facts, config, prices)
  end

  defp error({:error, :timeout}), do: "timeout"
  defp error({:error, reason}), do: CLI.message(reason)
  defp error({:ok, _answers}), do: nil

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

  defp resumption do
    {status, 0} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
    %{at: DateTime.utc_now(), commit: commit(), dirty: String.trim(status) != ""}
  end

  @doc "Writes `data` to `path` as pretty JSON."
  @spec write_json(Path.t(), term) :: :ok
  def write_json(path, data), do: File.write!(path, Jason.encode!(data, pretty: true))
end
