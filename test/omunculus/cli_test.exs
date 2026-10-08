defmodule Omunculus.CLITest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Project, Store}
  alias Omunculus.Store.Query
  alias Omunculus.Tools.Out

  import Omunculus.Fixtures,
    only: [
      open_project: 1,
      write_config: 2,
      write_hook: 4,
      write_model_tool: 2,
      write_model_tool: 3
    ]

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.install_default(dir)
    %{dir: dir}
  end

  defp create_root(call, title),
    do: call.("work", %{"report" => "opened", "works" => [%{"title" => title, "goal" => title}]})

  defp delegate_one(call, title, goal),
    do:
      call.("work", %{"report" => "delegated", "works" => [%{"title" => title, "goal" => goal}]})

  defp tool_event_names(events) do
    events
    |> Enum.filter(&(&1.type == "tool"))
    |> Enum.map(&Jason.decode!(&1.body)["name"])
  end

  test "format_error for not_logged_in", _ctx do
    assert CLI.format_error({:auth, :not_logged_in, "openai"}) =~
             "omunculus login --provider openai"
  end

  test "send delivers a message, opens a run and the run reaches done", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "count to 5"], dir)

    project = open_project(dir)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.run_id != nil

    assert {:ok, [assembled]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")

    assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
    assert run.status == "done"
    assert run.agent == "concierge"
    assert run.depth == "0"
    assert run.prompt_id == assembled.id

    assert {:ok, events} = Store.replay(project.conn, :project)

    assert Enum.map(events, & &1.type) == [
             "tool",
             "prompt",
             "start-run",
             "tool",
             "model",
             "end-run"
           ]

    assert assembled.body =~ "count to 5"
    assert assembled.body =~ "tools.*"
    refute assembled.body =~ "send"

    assert {:ok, []} = Query.all(project.conn, "SELECT * FROM works")

    Project.close(project)
  end

  test "each run records the event that made it due", %{dir: dir} do
    model = fn assembled, _tools, call ->
      cond do
        assembled =~ "You are the worker." ->
          call.("done", %{"report" => "answered"})

        assembled =~ "## Last comment\nanswered" or assembled =~ "## Last comment\ndelegated" ->
          call.("done", %{"report" => "closed"})

        assembled =~ "## Last comment\nopened" ->
          delegate_one(call, "Answer", "answer it")

        true ->
          create_root(call, "Root")
      end

      {:ok, "unused"}
    end

    Fixtures.use_model(dir, model)
    assert {:ok, ""} = CLI.run(["send", "hi"], dir)

    project = open_project(dir)

    {:ok, runs} =
      Query.all(
        project.conn,
        "SELECT runs.*, cause.type AS cause_type, cause.work_id AS cause_work FROM runs LEFT JOIN events AS cause ON cause.id = runs.cause_id ORDER BY runs.started_at"
      )

    assert [
             %{via: "send", cause_type: "prompt"},
             %{via: "work", cause_type: "work"},
             %{agent: "worker", via: "delegate", cause_type: "delegate", work_id: child},
             %{agent: "concierge", via: "continue", cause_type: "continue", cause_work: child}
           ] = runs

    Project.close(project)
  end

  test "a parent woken by its child reads the child's report and closes", %{dir: dir} do
    test_pid = self()

    model = fn assembled, _tools, call ->
      cond do
        assembled =~ "You are the worker." ->
          call.("done", %{"report" => "said hello back"})

        assembled =~ "\n\n## Results\n" ->
          send(test_pid, {:results, assembled})
          call.("done", %{"report" => "the worker said hello back"})

        assembled =~ "## Last comment\nopened" ->
          delegate_one(call, "Answer", "answer the greeting")

        true ->
          create_root(call, "Root")
      end

      {:ok, "unused"}
    end

    Fixtures.use_model(dir, model)
    assert {:ok, ""} = CLI.run(["send", "Alo"], dir)

    assert_received {:results, assembled}
    assert assembled =~ "## Results\n- Answer (worker, done): said hello back"

    project = open_project(dir)
    {:ok, runs} = Query.all(project.conn, "SELECT agent FROM runs ORDER BY started_at")
    assert Enum.map(runs, & &1.agent) == ["concierge", "concierge", "worker", "concierge"]

    {:ok, [root]} = Query.all(project.conn, "SELECT * FROM works WHERE parent_id IS NULL")
    assert root.state == "done"

    Project.close(project)
  end

  test "the --message form works", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "--message", "hello"], dir)

    project = open_project(dir)

    assert {:ok, [message]} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'message'")

    assert message.body == "hello"

    Project.close(project)
  end

  test "an unknown tool errors", %{dir: dir} do
    assert {:error, {:unknown_tool, "nope"}} = CLI.run(["nope"], dir)
  end

  test "a project another command holds without a server is in use", %{dir: dir} do
    {:ok, config} = Omunculus.Config.load(Fixtures.config_path(dir))
    {:ok, holder} = Project.open(config, lock: true)

    try do
      assert {:error, :project_in_use} = CLI.run(["send", "blocked"], dir)
    after
      Project.close(holder)
    end
  end

  test "prompt prints the last run assembled prompt", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "first message"], dir)
    assert {:ok, ""} = CLI.run(["send", "second message"], dir)

    assert {:ok, output} = CLI.run(["prompt"], dir)
    assert output =~ "second message"
    refute output =~ "first message"

    assert output =~
             "- read: Reads a file, or limit lines of it from line offset (from 1). [tags: fs]"

    assert output =~
             "- comment: Writes a comment on the work, request, or inbox. [tags: comment, work, store]"
  end

  test "prompt --run prints that run assembled prompt", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "first message"], dir)
    project = open_project(dir)
    assert {:ok, [first]} = Query.all(project.conn, "SELECT * FROM runs")
    first_id = first.id
    Project.close(project)

    assert {:ok, ""} = CLI.run(["send", "second message"], dir)

    assert {:ok, output} = CLI.run(["prompt", "--run", first_id], dir)
    assert output =~ "first message"
    refute output =~ "second message"
  end

  test "prompt without runs is a clear error", %{dir: dir} do
    assert {:error, :no_runs} = CLI.run(["prompt"], dir)
    assert CLI.format_error(:no_runs) == "no runs"
  end

  test "prompt --run with an unknown id is a clear error", %{dir: dir} do
    assert {:error, {:unknown_run, "missing"}} = CLI.run(["prompt", "--run", "missing"], dir)

    assert CLI.format_error({:unknown_run, "missing"}) == "unknown run missing"
  end

  test "an override that does not fit its manifest is a clear error" do
    assert CLI.format_error({:overrides, "done", {:not_chainable, "work"}}) ==
             "overrides.done.chains names work, which the done manifest does not chain"

    assert CLI.format_error({:overrides, "done", {:invalid, :then}}) ==
             "overrides of done leave a then outside its chains or with end not last"

    assert CLI.format_error({:overrides, "done", {:unknown_schema, "short"}}) ==
             "overrides.done.schema names short, which the done manifest does not declare"
  end

  test "send without a config file does not open a run", %{dir: dir} do
    path = Path.expand("omunculus.toml", dir)
    File.rm!(path)

    assert CLI.run(["send", "x"], dir) == {:error, {:config, :missing, path}}
    refute File.dir?(Path.join(dir, ".omunculus"))

    assert CLI.format_error({:config, :missing, path}) =~
             "run `omunculus preset <name> --from <dir>`"
  end

  test "preset default writes the config file without opening the store", %{dir: dir} do
    path = Path.expand("omunculus.toml", dir)
    File.rm!(path)

    assert {:ok, applied} =
             CLI.run(
               ["preset", "default", "--from", Fixtures.preset_dir("default")],
               dir
             )

    assert applied == Out.preset_applied("default")
    {:ok, config} = Omunculus.Config.load(path)
    assert Fixtures.package_tools() in config.tools.paths
    refute File.dir?(Path.join(dir, ".omunculus"))
  end

  test "--config uses that file; the project root is the file's directory", %{dir: dir} do
    File.rm!(Path.join(dir, "omunculus.toml"))
    other = Fixtures.tmp_dir()
    Fixtures.install_default(other)
    config = Path.join(other, "omunculus.toml")

    assert {:ok, ""} = CLI.run(["--config", config, "send", "x"], dir)
    assert File.dir?(Path.join(other, ".omunculus"))
    refute File.dir?(Path.join(dir, ".omunculus"))
  end

  test "--config with [project] root still stores next to the config file", %{dir: dir} do
    File.rm!(Path.join(dir, "omunculus.toml"))
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    config_dir = Path.join(dir, "cfg")
    File.mkdir_p!(config_dir)

    Fixtures.write_config(config_dir, """
    [project]
    root = "#{repo}"

    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["reply"]
    """)

    path = Path.join(config_dir, "omunculus.toml")
    assert {:ok, ""} = CLI.run(["--config", path, "send", "x"], dir)
    assert File.dir?(Path.join(config_dir, ".omunculus"))
    refute File.dir?(Path.join(repo, ".omunculus"))
  end

  test "a missing --config value is an error", %{dir: dir} do
    assert {:error, {:missing_value, "config"}} = CLI.run(["--config"], dir)
  end

  test "a config without [tools] opens a run with no tool cards", %{dir: dir} do
    write_config(dir, """
    [tools]

    [agents.concierge]
    depth = 0
    text = "hi"
    tools = ["comment", "reply"]
    """)

    model = fn assembled, tools, _call ->
      refute assembled =~ "- comment:"
      assert tools == []
      {:ok, "ok"}
    end

    Fixtures.use_model(dir, model)

    assert {:ok, ""} = CLI.run(["send", "x"], dir)
  end

  test "a missing [execution] table lists the required keys" do
    keys = [
      "backend",
      "runtimes",
      "environment",
      "timeout_ms",
      "max_output_bytes",
      "max_concurrent",
      "max_queue",
      "queue_timeout_ms",
      "resources"
    ]

    message = CLI.format_error({:execution, :missing, keys})
    assert message =~ "backend"
    assert message =~ "queue_timeout_ms"
    refute message =~ ":missing"
  end

  test "a missing [execution.sandbox] table is named in the error" do
    assert CLI.format_error({:execution, {:sandbox, :missing}}) =~ "[execution.sandbox]"
    assert CLI.format_error({:policy, {:invalid, :max_retries}}) =~ "[policy] max_retries"

    assert CLI.format_error({:policy, {:invalid, :last_run_output_bytes}}) =~
             "[policy] last_run_output_bytes"

    assert CLI.format_error({:policy, {:invalid, :tool_output_bytes}}) =~
             "[policy] tool_output_bytes"
  end

  test "send with no args fails and reports the tool's own output", %{dir: dir} do
    assert {:error, {:tool_failed, "message required"}} = CLI.run(["send"], dir)
  end

  test "a second send never reuses the old assembled prompt", %{dir: dir} do
    assert {:ok, ""} = CLI.run(["send", "first"], dir)
    assert {:ok, ""} = CLI.run(["send", "second"], dir)

    project = open_project(dir)

    assert {:ok, assembleds} =
             Query.all(project.conn, "SELECT * FROM prompts WHERE kind = 'assembled'")

    assert length(assembleds) == 2
    assert assembleds |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2

    Project.close(project)
  end

  describe "work + comment" do
    test "the concierge creates the work, a follow-up comments on it, and a third opening sees the last comment",
         %{dir: dir} do
      model = fn assembled, _tools, call ->
        if assembled =~ "## Work", do: call.("end", %{}), else: create_root(call, "Count to five")
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Count to 5"], dir)

      project = open_project(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.title == "Count to five"
      assert work.title != "Count to 5"
      assert work.assignee == "concierge"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs")
      assert Enum.map(runs, & &1.work_id) == [work.id, work.id]

      assert {:ok, events} = Store.replay(project.conn, :project)

      assert Enum.map(events, & &1.type) ==
               ["tool", "prompt", "start-run", "tool", "tool", "work", "tool", "end", "end-run"] ++
                 ["start-run", "tool", "tool", "end", "end-run"]

      assert {:ok, [first_assembled, _root_assembled]} =
               Query.all(
                 project.conn,
                 "SELECT prompts.* FROM prompts JOIN runs ON runs.prompt_id = prompts.id JOIN events ON events.id = runs.event_id WHERE kind = 'assembled' ORDER BY events.sequence"
               )

      Project.close(project)

      test_pid = self()

      model = fn assembled, _tools, call ->
        send(test_pid, {:second_assembled, assembled})
        assert {:ok, ""} = call.("comment", %{"body" => "first comment"})
        call.("end", %{})
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "keep going"], dir)

      assert_received {:second_assembled, second_assembled}
      assert second_assembled =~ "## Work"
      assert second_assembled =~ work.title
      assert second_assembled =~ "## Message\nkeep going"
      refute second_assembled =~ "Count to 5"
      refute second_assembled =~ first_assembled.body

      project = open_project(dir)

      assert {:ok, [report, comment]} =
               Query.all(project.conn, "SELECT * FROM comments ORDER BY created_at")

      assert report.body == "opened"
      assert comment.work_id == work.id
      assert comment.body == "first comment"

      Project.close(project)

      model = fn assembled, _tools, _call ->
        send(test_pid, {:third_assembled, assembled})
        {:ok, "seen"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "again"], dir)

      assert_received {:third_assembled, third_assembled}
      assert third_assembled =~ "## Last comment"
      assert third_assembled =~ "first comment"
    end

    test "send --work_id pointing at a work that does not exist refuses and leaves events untouched",
         %{dir: dir} do
      assert {:error, {:prompt, {:missing, :works, "nope"}}} =
               CLI.run(["send", "--work_id", "nope", "x"], dir)

      project = open_project(dir)
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM events")
      Project.close(project)
    end
  end

  describe "request and reply" do
    setup %{dir: dir} do
      write_model_tool(dir, "write")
      :ok
    end

    defp open_write_request(dir, work_id \\ nil) do
      model = fn _assembled, _tools, call ->
        call.("request_access", %{
          "report" => "blocked on write",
          "kind" => "tool",
          "name" => "write",
          "reason" => "need to write"
        })

        {:ok, "unused"}
      end

      args =
        if work_id,
          do: ["send", "--work_id", work_id, "save this"],
          else: ["send", "save this"]

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(args, dir)

      project = open_project(dir)
      assert {:ok, [request]} = Query.all(project.conn, "SELECT * FROM requests")
      Project.close(project)

      request.id
    end

    test "an askable request opens REQUESTS waiting_human, comments the reason, and parks a linked work on the request",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open_project(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "waiting_human"
      assert request.arbiter == "human"

      assert %{"deny" => [], "grant" => [%{"name" => "grant"}]} =
               Jason.decode!(request.options)

      assert {:ok, [comment]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE request_id = ?", [
                 request_id
               ])

      assert comment.body == "need to write"

      assert {:ok, [report]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE work_id = ?", [work_id])

      assert report.body == "blocked on write"

      assert {:ok, events} = Store.replay(project.conn, :project)
      types = events |> Enum.map(& &1.type) |> Enum.drop_while(&(&1 != "comment"))
      assert ["comment", "request", "tool", "end" | _rest] = types

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "waiting"
      assert work.waiting == "request"
      assert work.waiting_for == request_id

      Project.close(project)
    end

    test "reply grant adds the name to works.grants, reopens the work, and opens a new run on the same stage with the granted tool",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open_project(dir)
      assert {:ok, [old_run]} = Query.all(project.conn, "SELECT * FROM runs")
      Project.close(project)

      model = fn _assembled, _tools, call -> call.("end", %{}) end
      Fixtures.use_model(dir, model)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--option", "grant", "allowed"],
                 dir
               )

      project = open_project(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "closed"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["write"]
      assert work.state == "open"

      assert {:ok, runs} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [work_id])

      assert length(runs) == 2
      new_run = Enum.find(runs, &(&1.id != old_run.id))
      assert "write" in Jason.decode!(new_run.tools)
      refute "write" in Jason.decode!(old_run.tools)
      assert new_run.request_id == request_id

      assert {:ok, new_assembled} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [new_run.prompt_id])

      assert new_assembled.body =~ "## Work"
      refute new_assembled.body =~ "## Message"

      Project.close(project)
    end

    test "reply grant with scope agent writes the permanent grant to the project's omunculus.toml, leaves works.grants untouched, and a fresh work also gets the tool",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      model = fn _assembled, _tools, call -> call.("end", %{}) end
      Fixtures.use_model(dir, model)

      assert {:ok, ""} =
               CLI.run(
                 [
                   "reply",
                   "--request_id",
                   request_id,
                   "--option",
                   "grant_agent",
                   "allowed forever"
                 ],
                 dir
               )

      project = open_project(dir)
      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.grants == nil
      Project.close(project)

      assert {:ok, config} = Fixtures.load_config(dir)
      assert "write" in config.agents["concierge"].ceiling.granted

      project = open_project(dir)
      other_work_id = Fixtures.insert(project.conn, :works, %{title: "Another one"})
      Project.close(project)

      model = fn _assembled, _tools, call -> call.("end", %{}) end
      Fixtures.use_model(dir, model)
      assert {:ok, ""} = CLI.run(["send", "--work_id", other_work_id, "new request"], dir)

      project = open_project(dir)

      assert {:ok, [run]} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [other_work_id])

      assert "write" in Jason.decode!(run.tools)
      Project.close(project)
    end

    test "a blocked request denies immediately, opens no REQUESTS row, and the run reaches done",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["comment", "end", "request_access", "work"]
      deny = ["write"]
      """)

      model = fn _assembled, _tools, call ->
        call.("request_access", %{
          "report" => "blocked on write",
          "kind" => "tool",
          "name" => "write",
          "reason" => "need it"
        })

        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "save"], dir)

      project = open_project(dir)

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")

      assert {:ok, events} = Store.replay(project.conn, :project)
      assert "deny" in Enum.map(events, & &1.type)

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      Project.close(project)
    end

    test "request_access for a name the run already has opens no REQUESTS and still ends the run",
         %{dir: dir} do
      test_pid = self()

      model = fn _assembled, _tools, call ->
        call.("request_access", %{
          "report" => "checking comment",
          "kind" => "tool",
          "name" => "comment",
          "reason" => "just checking"
        })

        send(test_pid, :reached_after_request)
        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)
      refute_received :reached_after_request

      project = open_project(dir)
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM comments")

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert "end" in Enum.map(events, & &1.type)

      Project.close(project)
    end

    test "a request emit for a name the run already has opens no REQUESTS and lets the model keep calling tools",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "hi"
      tools = ["ask_comment", "comment"]
      """)

      write_model_tool(
        dir,
        "ask_comment",
        ~s({"ok": true, "output": "", "emit": [{"type": "request", "body": {"reason": "just checking", "options": {"grant": [{"name": "grant", "args": {"kind": "tool", "name": "comment"}}]}}}]})
      )

      test_pid = self()

      model = fn _assembled, _tools, call ->
        assert {:ok, output} = call.("ask_comment", %{})
        send(test_pid, {:output, output})
        {:ok, "continuing"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      assert_received {:output, output}
      assert output =~ Out.already_granted("comment")

      project = open_project(dir)
      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")

      assert {:ok, [run]} = Query.all(project.conn, "SELECT * FROM runs")
      assert run.status == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert "model" in Enum.map(events, & &1.type)

      Project.close(project)
    end

    test "reply deny closes the request, reopens the work and opens its run with the request",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)
      test_pid = self()

      model = fn assembled, _tools, call ->
        send(test_pid, {:assembled, assembled})
        call.("end", %{})
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--option", "deny", "not allowed"],
                 dir
               )

      assert_received {:assembled, assembled}
      assert assembled =~ "## Request"
      assert assembled =~ "not allowed"

      project = open_project(dir)

      assert {:ok, %{status: "closed"}} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.state == "open"
      assert work.grants == nil

      assert {:ok, [_old_run, new_run]} =
               Query.all(
                 project.conn,
                 "SELECT * FROM runs WHERE work_id = ? ORDER BY started_at",
                 [
                   work_id
                 ]
               )

      assert new_run.request_id == request_id
      assert new_run.via == "reply"
      refute "write" in Jason.decode!(new_run.tools)

      Project.close(project)
    end

    test "a request without a linked work has no work_id; the reply runs its agent again with the request and the asking run",
         %{dir: dir} do
      request_id = open_write_request(dir)

      project = open_project(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.work_id == nil
      Project.close(project)

      test_pid = self()

      model = fn assembled, _tools, call ->
        send(test_pid, {:assembled, assembled})
        call.("end", %{})
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--option", "grant_agent", "allowed"],
                 dir
               )

      assert_received {:assembled, assembled}
      assert assembled =~ "## Request\n#{request_id}"
      assert assembled =~ "allowed"
      assert assembled =~ "## Last run\n- message save this"
      assert assembled =~ "- tool request_access"

      project = open_project(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)
      assert "grant" in Enum.map(events, & &1.type)

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM works")

      assert {:ok, [asking, again]} =
               Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")

      assert again.via == "reply"
      assert again.agent == asking.agent
      assert again.request_id == request_id
      assert "write" in Jason.decode!(again.tools)

      Project.close(project)
    end

    test "replying twice to the same request fails the second time", %{dir: dir} do
      request_id = open_write_request(dir)
      model = fn _assembled, _tools, call -> call.("end", %{}) end
      Fixtures.use_model(dir, model)

      assert {:ok, ""} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--option", "deny", "no"],
                 dir
               )

      Fixtures.use_model(dir, model)

      assert {:error, {:reply, :closed}} =
               CLI.run(
                 ["reply", "--request_id", request_id, "--option", "deny", "again"],
                 dir
               )
    end

    @tag :sandbox
    test "a project on-request hook emitting notify triggers on-notify without sequencing",
         %{dir: dir} do
      write_hook(
        dir,
        "on-request",
        """
        name = "on-request"
        kind = "hook"
        events = ["request"]
        command = ["./run"]
        """,
        """
        #!/bin/sh
        echo '{"ok": true, "output": "", "emit": [{"type": "notify", "body": {"body": "open request"}}]}'
        """
      )

      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open_project(dir)

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "waiting_human"

      assert {:ok, [_inbox_row]} = Query.all(project.conn, "SELECT * FROM inbox")

      assert {:ok, events} = Store.replay(project.conn, :project)
      tool_names = tool_event_names(events)

      assert "on-request" in tool_names
      assert "on-notify" in tool_names

      Project.close(project)
    end
  end

  describe "sequence and child" do
    test "D0-H0-W1: done moves a work through the workflow's steps and the last stage closes it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["work", "continue", "comment", "done", "end"]

      [agents.reviewer]
      depth = 0
      text = "I am the reviewer."
      tools = ["work", "continue", "comment", "done", "end"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "reviewer", deny = ["work"] },
      ]

      [policy]
      workflow = "delivery"
      """)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "I am the concierge." ->
            if assembled =~ "## Work",
              do: call.("done", %{"report" => "built"}),
              else: create_root(call, "Ship it")

            {:ok, "unused"}

          assembled =~ "I am the reviewer." ->
            call.("done", %{"report" => "reviewed"})
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Ship it please"], dir)

      project = open_project(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "done"
      assert work.stage == "review"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 3
      [creation, run1, run2] = runs
      assert creation.agent == "concierge"
      assert run1.via == "work"

      assert run1.agent == "concierge"
      assert run2.agent == "reviewer"
      assert run2.depth == "0"
      assert run2.via == "continue"

      assert {:ok, events1} = Store.replay(project.conn, {:run, run1.id})
      types1 = Enum.map(events1, & &1.type)
      refute "model" in types1
      continue_at = Enum.find_index(types1, &(&1 == "continue"))
      assert Enum.at(types1, continue_at + 2) == "end"
      hook = Enum.at(events1, continue_at + 3)
      assert hook.type == "tool"
      assert Jason.decode!(hook.body)["name"] == "on-continue"
      assert List.last(types1) == "end-run"

      assert {:ok, assembled2} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [run2.prompt_id])

      assert assembled2.body =~ "## Work"
      refute assembled2.body =~ "- work:"

      Project.close(project)
    end

    test "done without a workflow closes a root work and ends the run", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "comment", "continue", "done", "end"]
      """)

      model = fn assembled, _tools, call ->
        if assembled =~ "## Work",
          do: call.("done", %{"report" => "closed"}),
          else: create_root(call, "No sequence")

        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)

      assert {:ok, [_creation, run]} =
               Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")

      assert run.status == "done"

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      refute "model" in Enum.map(events, & &1.type)
      continue = Enum.find(events, &(&1.type == "continue"))
      assert Jason.decode!(continue.body) == %{"from" => nil, "to" => nil, "parent_id" => nil}

      Project.close(project)
    end

    test "a continue emit naming a stage is refused by the store", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "bad_continue", "end", "sandbox.network"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "concierge" },
      ]

      [policy]
      workflow = "delivery"
      """)

      write_model_tool(
        dir,
        "bad_continue",
        ~s({"ok": true, "output": "", "emit": [{"type": "continue", "body": {"stage": "review"}}]})
      )

      model = fn assembled, _tools, call ->
        unless assembled =~ "## Work",
          do: create_root(call, "Ship it")

        assert {:error, {:continue, {:forbidden, "stage"}}} = call.("bad_continue", %{})

        {:ok, "continuing"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)
      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.stage == "to_do"
      Project.close(project)
    end

    test "a grant on the work survives a stage deny: the effective set loses it but works.grants keeps it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["counter", "comment", "continue", "done", "end"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "concierge" },
        { name = "review", agent = "concierge", deny = ["counter"] },
      ]

      [policy]
      workflow = "delivery"
      """)

      write_model_tool(dir, "counter")

      project = open_project(dir)

      work_id =
        Fixtures.insert(project.conn, :works, %{
          stage: "to_do",
          assignee: "concierge",
          grants: ~s(["counter"])
        })

      Project.close(project)

      model = fn assembled, _tools, call ->
        if assembled =~ "- counter:" do
          call.("done", %{"report" => "counted"})
          {:ok, "unused"}
        else
          {:ok, "done"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "go on"], dir)

      project = open_project(dir)

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 2
      review_run = List.last(runs)
      refute "counter" in Jason.decode!(review_run.tools)

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert Jason.decode!(work.grants) == ["counter"]

      Project.close(project)
    end

    test "break parks the work with a comment without moving the stage, and a later send reopens a run on it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "break", "comment", "end"]

      [workflows.solo]
      steps = [{ name = "to_do", agent = "concierge" }]

      [policy]
      workflow = "solo"
      """)

      model = fn assembled, _tools, call ->
        if assembled =~ "## Work",
          do: call.("break", %{"report" => "need to pause"}),
          else: create_root(call, "Needs help")

        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "handle this"], dir)

      project = open_project(dir)
      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "waiting"
      assert work.stage == "to_do"
      assert work.waiting_from == "concierge"

      assert {:ok, [report, comment]} =
               Query.all(project.conn, "SELECT * FROM comments ORDER BY created_at")

      assert report.body == "opened"
      assert comment.body == "need to pause"

      assert {:ok, previous_runs} = Query.all(project.conn, "SELECT * FROM runs")
      assert length(previous_runs) == 2
      Project.close(project)

      model = fn _assembled, _tools, call -> call.("end", %{}) end
      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "come back"], dir)

      project = open_project(dir)

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs")
      assert length(runs) == 3
      run2 = Enum.find(runs, &(&1.id not in Enum.map(previous_runs, fn run -> run.id end)))
      assert run2.agent == "concierge"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work.id])
      assert work.stage == "to_do"
      assert work.state == "open"
      assert work.waiting == nil

      Project.close(project)
    end

    test "D1-H0-W0: delegate opens a child run, the child finishing wakes the parent, and the parent's end-run precedes the child's start-run",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["work", "delegate", "comment", "end"]

      [agents.worker]
      depth = 1
      text = "I am the worker."
      tools = ["comment", "continue", "done", "end"]
      """)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "I am the worker." ->
            call.("done", %{"report" => "finished"})

          assembled =~ "## Last comment\nopened" ->
            delegate_one(call, "Sub task", "do this")
            {:ok, "unused"}

          assembled =~ "## Work" ->
            call.("end", %{})

          true ->
            create_root(call, "Big task")
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Big task please"], dir)

      project = open_project(dir)

      assert {:ok, works} = Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert parent.state == "open"
      assert child.state == "done"
      assert child.assignee == "worker"
      assert child.parent_id == parent.id
      assert child.goal == "do this"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 4
      [_creation, run1, run2, run3] = runs

      assert run1.agent == "concierge"
      assert run1.work_id == parent.id
      assert run2.agent == "worker"
      assert run2.depth == "1"
      assert run2.via == "delegate"
      assert run3.agent == "concierge"
      assert run3.depth == "0"

      assert {:ok, assembled2} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [run2.prompt_id])

      assert assembled2.body =~ "Sub task"
      assert assembled2.body =~ "## Goal\ndo this"
      refute assembled2.body =~ "## Last comment"

      assert {:ok, project_events} = Store.replay(project.conn, :project)

      end_run1 = Enum.find(project_events, &(&1.type == "end-run" and &1.run_id == run1.id))
      start_run2 = Enum.find(project_events, &(&1.type == "start-run" and &1.run_id == run2.id))
      assert end_run1.sequence < start_run2.sequence

      Project.close(project)
    end

    for {tool, args, tools, action, workflow?, child_state} <- [
          {"done", %{"report" => "finished"}, ~w(comment continue done end), "continue", false,
           "done"},
          {"break", %{"report" => "stuck"}, ~w(break end), "break", false, "waiting"},
          {"break", %{"report" => "stuck"}, ~w(break end), "break", true, "waiting"}
        ] do
      test "#{tool} #{if workflow?, do: "with", else: "without"} a workflow hands the child back to its waiting parent and opens the parent's run",
           %{dir: dir} do
        workflow =
          if unquote(workflow?),
            do: """

            [workflows.solo]
            steps = [{ name = "to_do", agent = "worker" }]

            [policy.depth.1]
            workflow = "solo"
            """,
            else: ""

        write_config(
          dir,
          """
          [agents.concierge]
          depth = 0
          text = "I am the concierge."
          tools = ["work", "delegate", "comment", "end"]

          [agents.worker]
          depth = 1
          text = "I am the worker."
          tools = #{inspect(unquote(tools))}
          """ <> workflow
        )

        model = fn assembled, _tools, call ->
          cond do
            assembled =~ "I am the worker." ->
              call.(unquote(tool), unquote(Macro.escape(args)))
              {:ok, "unused"}

            assembled =~ "## Last comment\nopened" ->
              delegate_one(call, "Sub task", "do this")
              {:ok, "unused"}

            assembled =~ "## Work" ->
              call.("end", %{})

            true ->
              create_root(call, "Big task")
              {:ok, "unused"}
          end
        end

        Fixtures.use_model(dir, model)

        assert {:ok, ""} = CLI.run(["send", "Big task please"], dir)

        project = open_project(dir)

        assert {:ok, [parent, child]} =
                 Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")

        assert parent.state == "open"
        assert parent.waiting == nil
        assert child.state == unquote(child_state)

        assert {:ok, [_creation, _run1, run2, run3]} =
                 Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")

        assert run2.work_id == child.id
        assert run3.work_id == parent.id
        assert run3.agent == "concierge"

        assert {:ok, events} = Store.replay(project.conn, {:run, run2.id})
        event = Enum.find(events, &(&1.type == unquote(action)))
        assert Jason.decode!(event.body)["parent_id"] == parent.id
        assert "end" in Enum.map(events, & &1.type)

        Project.close(project)
      end
    end

    test "D1-H0-W1: the child follows its own depth-scoped workflow through the parent's agents",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["work", "delegate", "comment", "continue", "done", "end"]

      [agents.worker]
      depth = 1
      text = "I am the worker."
      tools = ["comment", "continue", "done", "end"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "worker" },
        { name = "review", agent = "concierge" },
      ]

      [policy.depth.0.overrides.work]
      schema = "staged"

      [policy.depth.1]
      workflow = "delivery"
      """)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "I am the worker." ->
            call.("done", %{"report" => "built"})
            {:ok, "unused"}

          assembled =~ "## Work\nSub task2" ->
            call.("done", %{"report" => "reviewed"})
            {:ok, "unused"}

          assembled =~ "## Last comment\nopened" ->
            delegate_one(call, "Sub task2", "do this 2")
            {:ok, "unused"}

          assembled =~ "## Work" ->
            call.("end", %{})

          true ->
            create_root(call, "Big task2")
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Big task2 please"], dir)

      project = open_project(dir)

      assert {:ok, works} = Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert parent.state == "open"
      assert child.state == "done"
      assert child.stage == "review"

      assert {:ok, runs} = Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")
      assert length(runs) == 5
      [_creation, run1, run2, run3, run4] = runs

      assert run1.agent == "concierge" and run1.depth == "0"
      assert run2.agent == "worker" and run2.depth == "1"
      assert run3.agent == "concierge" and run3.depth == "1"
      assert run4.agent == "concierge" and run4.depth == "0"

      Project.close(project)
    end

    test "an askable request with an agent arbiter opens a run on the parent, and granting it wakes the child with the new tool",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["work", "delegate", "comment", "end", "grant", "reply", "write"]

      [agents.worker]
      depth = 1
      text = "I am the worker."
      tools = ["comment", "continue", "done", "end", "request_access"]
      """)

      reader = open_project(dir)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> Project.close(reader) end)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "I am the worker." ->
            case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
              0 ->
                call.("request_access", %{
                  "report" => "blocked on write",
                  "kind" => "tool",
                  "name" => "write",
                  "reason" => "need to write"
                })

                {:ok, "unused"}

              _already_granted ->
                call.("done", %{"report" => "written"})
            end

          assembled =~ "## Request" ->
            assert {:ok, [request]} =
                     Query.all(
                       reader.conn,
                       "SELECT * FROM requests WHERE status = 'waiting_agent'"
                     )

            assert {:ok, ""} =
                     call.("reply", %{
                       "request_id" => request.id,
                       "option" => "grant",
                       "body" => "you may write"
                     })

            {:ok, "granted"}

          assembled =~ "## Last comment\nopened" ->
            delegate_one(call, "Sub task3", "write this")
            {:ok, "unused"}

          assembled =~ "## Work" ->
            call.("end", %{})

          true ->
            create_root(call, "Big task3")
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Big task3 please"], dir)

      assert {:ok, [request]} = Query.all(reader.conn, "SELECT * FROM requests")
      assert request.status == "closed"
      assert request.arbiter == "concierge"

      assert {:ok, request_run} =
               Query.one(reader.conn, "SELECT * FROM runs WHERE request_id IS NOT NULL")

      assert request_run.agent == "concierge"

      assert {:ok, request_assembled} =
               Query.one(reader.conn, "SELECT * FROM prompts WHERE id = ?", [
                 request_run.prompt_id
               ])

      assert request_assembled.body =~ "## Request"
      assert request_assembled.body =~ "need to write"

      assert {:ok, works} = Query.all(reader.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert Jason.decode!(child.grants) == ["write"]
      assert child.state == "done"
      assert parent.state == "open"

      assert {:ok, runs} = Query.all(reader.conn, "SELECT * FROM runs ORDER BY started_at")

      granted_worker_run =
        Enum.find(runs, fn run ->
          run.work_id == child.id and run.agent == "worker" and
            "write" in Jason.decode!(run.tools)
        end)

      assert granted_worker_run

      assert List.last(runs).agent == "concierge"
    end
  end

  describe "inbox" do
    test "notify mid-run leaves an unread inbox row, the run keeps going and closes done, the work stays open, and CLI reads it",
         %{dir: dir} do
      model = fn assembled, _tools, call ->
        unless assembled =~ "## Work", do: create_root(call, "Help")
        assert {:ok, ""} = call.("notify", %{"body" => "need help"})
        call.("end", %{})
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "open"

      assert {:ok, [inbox_row]} = Query.all(project.conn, "SELECT * FROM inbox")
      assert inbox_row.agent == "concierge"

      assert {:ok, [comment]} =
               Query.all(project.conn, "SELECT * FROM comments WHERE inbox_id = ?", [
                 inbox_row.id
               ])

      assert comment.body == "need help"

      assert {:ok, [_creation, run]} =
               Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")

      assert run.status == "done"

      assert {:ok, events} = Store.replay(project.conn, {:run, run.id})
      assert "notify" in Enum.map(events, & &1.type)

      Project.close(project)

      expected_line = "#{inbox_row.id} concierge: need help"
      assert {:ok, ^expected_line} = CLI.run(["inbox"], dir)
      assert {:ok, ""} = CLI.run(["inbox_read", inbox_row.id], dir)

      project = open_project(dir)

      assert {:ok, read} =
               Query.one(project.conn, "SELECT * FROM inbox WHERE id = ?", [inbox_row.id])

      assert read.read_at != nil

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM requests")

      Project.close(project)

      assert {:ok, empty} = CLI.run(["inbox"], dir)
      assert empty == Out.empty_inbox()
    end
  end

  describe "D0-H1-W0: builtin no-op hooks" do
    setup %{dir: dir} do
      write_model_tool(dir, "write")
      :ok
    end

    test "a request emits a tool event named on-request right after the call's chain, carrying the call's run and work ids",
         %{dir: dir} do
      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      request_id = open_write_request(dir, work_id)

      project = open_project(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)

      request_event = Enum.find(events, &(&1.type == "request"))
      end_event = Enum.find(events, &(&1.type == "end-run" and &1.run_id == request_event.run_id))

      hook_event =
        Enum.find(events, fn event ->
          event.type == "tool" and Jason.decode!(event.body)["name"] == "on-request"
        end)

      chain_end = Enum.find(events, &(&1.type == "end" and &1.run_id == request_event.run_id))
      assert request_event.sequence < chain_end.sequence
      assert hook_event.sequence == chain_end.sequence + 1
      assert hook_event.sequence < end_event.sequence
      assert hook_event.run_id == request_event.run_id
      assert hook_event.work_id == request_event.work_id

      assert {:ok, request} =
               Query.one(project.conn, "SELECT * FROM requests WHERE id = ?", [request_id])

      assert request.status == "waiting_human"

      Project.close(project)
    end

    test "a notify emits a tool event named on-notify right after it, carrying the call's run and work ids",
         %{dir: dir} do
      model = fn _assembled, _tools, call ->
        assert {:ok, ""} = call.("notify", %{"body" => "notice"})
        {:ok, "ok"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)
      types = Enum.map(events, & &1.type)

      notify_index = Enum.find_index(types, &(&1 == "notify"))
      assert Enum.at(types, notify_index + 1) == "tool"

      notify_event = Enum.at(events, notify_index)
      hook_event = Enum.at(events, notify_index + 1)

      assert Jason.decode!(hook_event.body)["name"] == "on-notify"
      assert hook_event.run_id == notify_event.run_id
      assert hook_event.work_id == notify_event.work_id

      Project.close(project)
    end

    test "a continue with a workflow on emits a tool event named on-continue right after the call's chain",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "comment", "continue", "done", "end"]

      [workflows.solo]
      steps = [{ name = "to_do", agent = "concierge" }]

      [policy]
      workflow = "solo"
      """)

      model = fn assembled, _tools, call ->
        if assembled =~ "## Work",
          do: call.("done", %{"report" => "shipped"}),
          else: create_root(call, "Ship it")

        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)

      continue_event = events |> Enum.filter(&(&1.type == "continue")) |> List.last()

      end_event =
        Enum.find(events, &(&1.type == "end-run" and &1.run_id == continue_event.run_id))

      hook_event =
        Enum.find(events, fn event ->
          event.type == "tool" and Jason.decode!(event.body)["name"] == "on-continue"
        end)

      chain_end = Enum.find(events, &(&1.type == "end" and &1.run_id == continue_event.run_id))
      assert continue_event.sequence < chain_end.sequence
      assert hook_event.sequence == chain_end.sequence + 1
      assert hook_event.sequence < end_event.sequence
      assert hook_event.run_id == continue_event.run_id

      Project.close(project)
    end

    test "a break emits a tool event named on-break right after the call's chain", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "break", "comment", "end"]

      [workflows.solo]
      steps = [{ name = "to_do", agent = "concierge" }]

      [policy]
      workflow = "solo"
      """)

      model = fn assembled, _tools, call ->
        if assembled =~ "## Work",
          do: call.("break", %{"report" => "need to pause"}),
          else: create_root(call, "Needs help")

        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "handle this"], dir)

      project = open_project(dir)
      assert {:ok, events} = Store.replay(project.conn, :project)

      break_event = Enum.find(events, &(&1.type == "break"))
      end_event = Enum.find(events, &(&1.type == "end-run" and &1.run_id == break_event.run_id))

      hook_event =
        Enum.find(events, fn event ->
          event.type == "tool" and Jason.decode!(event.body)["name"] == "on-break"
        end)

      chain_end = Enum.find(events, &(&1.type == "end" and &1.run_id == break_event.run_id))
      assert break_event.sequence < chain_end.sequence
      assert hook_event.sequence == chain_end.sequence + 1
      assert hook_event.sequence < end_event.sequence
      assert hook_event.run_id == break_event.run_id

      Project.close(project)
    end
  end

  describe "hook calling an agent" do
    test "a hook declaring an agent opens a reaction run via the hook's name after the triggering run closes",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["notify", "sandbox.network"]
      """)

      write_hook(
        dir,
        "on-notify",
        """
        name = "on-notify"
        kind = "hook"
        events = ["notify"]
        agent = "concierge"
        command = ["./run"]
        """,
        """
        #!/bin/sh
        echo '{"ok": true, "output": "", "emit": []}'
        """
      )

      project = open_project(dir)
      work_id = Fixtures.insert(project.conn, :works, %{title: "Ship it"})
      Project.close(project)

      model = fn assembled, _tools, call ->
        if assembled =~ "## Message" do
          assert {:ok, ""} = call.("notify", %{"body" => "notice"})
          {:ok, "ok"}
        else
          {:ok, "reacted"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work_id, "handle"], dir)

      project = open_project(dir)

      assert {:ok, runs} =
               Query.all(project.conn, "SELECT * FROM runs WHERE work_id = ?", [work_id])

      assert length(runs) == 2

      reaction = Enum.find(runs, &(&1.via == "on-notify"))
      assert reaction
      assert reaction.agent == "concierge"

      assert {:ok, work} = Query.one(project.conn, "SELECT * FROM works WHERE id = ?", [work_id])
      assert work.stage == nil

      assert {:ok, events} = Store.replay(project.conn, :project)
      refute "continue" in Enum.map(events, & &1.type)

      Project.close(project)
    end

    test "a hook that emits continue on a work without a workflow closes it",
         %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["work", "end", "notify", "sandbox.network"]
      """)

      write_hook(
        dir,
        "on-notify",
        """
        name = "on-notify"
        kind = "hook"
        events = ["notify"]
        command = ["./run"]
        """,
        """
        #!/bin/sh
        echo '{"ok": true, "output": "", "emit": [{"type": "continue", "body": {}}]}'
        """
      )

      model = fn assembled, _tools, call ->
        unless assembled =~ "## Work", do: create_root(call, "Ship it")
        call.("notify", %{"body" => "notice"})
        {:ok, "unused"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "hi"], dir)

      project = open_project(dir)

      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert work.state == "done"

      assert {:ok, events} = Store.replay(project.conn, :project)
      assert "on-notify" in tool_event_names(events)
      assert "continue" in Enum.map(events, & &1.type)

      Project.close(project)
    end
  end

  describe "v1.1: compact and reviewer" do
    test "compact through the run cycle", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["comment", "compact_comments", "end", "work"]
      """)

      model1 = fn assembled, _tools, call ->
        unless assembled =~ "## Work", do: create_root(call, "Tally")
        assert {:ok, ""} = call.("comment", %{"body" => "one"})
        assert {:ok, ""} = call.("comment", %{"body" => "two"})
        assert {:ok, ""} = call.("comment", %{"body" => "three"})
        call.("end", %{})
      end

      Fixtures.use_model(dir, model1)

      assert {:ok, ""} = CLI.run(["send", "count the steps"], dir)

      project = open_project(dir)
      assert {:ok, [work]} = Query.all(project.conn, "SELECT * FROM works")
      assert {:ok, comments} = Store.comments(project.conn, :work, work.id)
      assert Enum.map(comments, & &1.body) == ["opened", "one", "two", "three"]
      Project.close(project)

      test_pid = self()

      model2 = fn _assembled, _tools, call ->
        assert {:ok, load_output} = call.("compact_comments", %{"op" => "load"})
        send(test_pid, {:load_output, load_output})

        assert {:ok, ""} =
                 call.("compact_comments", %{"op" => "commit", "summary" => "summary: 1 2 3"})

        call.("end", %{})
      end

      Fixtures.use_model(dir, model2)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "compact"], dir)

      assert_received {:load_output, load_output}
      expected = comments |> Enum.map(&"#{&1.id} #{&1.author}: #{&1.body}") |> Enum.join("\n")
      assert load_output == expected

      project = open_project(dir)

      assert {:ok, [summary]} = Store.comments(project.conn, :work, work.id)
      assert summary.body == "summary: 1 2 3"

      assert {:ok, work_events} = Store.replay(project.conn, {:work, work.id})
      comment_events = Enum.filter(work_events, &(&1.type in ["work", "comment"]))
      assert Enum.map(comment_events, & &1.comment_id) == Enum.map(comments, & &1.id)

      compact_event = Enum.find(work_events, &(&1.type == "compact"))
      assert compact_event
      assert Jason.decode!(compact_event.body)["deleted"] == Enum.map(comments, & &1.id)

      assert {:ok, [_creation, _run1, run2]} =
               Query.all(project.conn, "SELECT * FROM runs ORDER BY started_at")

      assert {:ok, run2_events} = Store.replay(project.conn, {:run, run2.id})
      assert tool_event_names(run2_events) |> Enum.count(&(&1 == "compact_comments")) == 2

      Project.close(project)

      model3 = fn assembled, _tools, _call ->
        send(test_pid, {:third_assembled, assembled})
        {:ok, "seen"}
      end

      Fixtures.use_model(dir, model3)

      assert {:ok, ""} = CLI.run(["send", "--work_id", work.id, "again"], dir)

      assert_received {:third_assembled, third_assembled}
      assert third_assembled =~ "## Last comment\nsummary: 1 2 3"
      refute third_assembled =~ ~r/^one$/m
      refute third_assembled =~ ~r/^two$/m
      refute third_assembled =~ ~r/^three$/m
    end

    test "compact refuses another work", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "concierge"
      tools = ["comment", "compact_comments", "foreign_compact", "work", "sandbox.network"]
      """)

      project = open_project(dir)
      my_work_id = Fixtures.insert(project.conn, :works, %{title: "My work"})
      other_work_id = Fixtures.insert(project.conn, :works, %{title: "Other work"})

      other_comment_id =
        Fixtures.insert(project.conn, :comments, %{work_id: other_work_id, body: "do not touch"})

      Project.close(project)

      write_model_tool(
        dir,
        "foreign_compact",
        ~s({"ok": true, "output": "", "emit": [{"type": "compact", "body": {"work_id": "#{other_work_id}", "summary": "stolen"}}]})
      )

      model = fn _assembled, _tools, call ->
        assert {:error, {:compact, :foreign_work}} = call.("foreign_compact", %{})
        {:ok, "ok"}
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "--work_id", my_work_id, "compact"], dir)

      project = open_project(dir)

      assert {:ok, [comment]} = Store.comments(project.conn, :work, other_work_id)
      assert comment.id == other_comment_id
      assert comment.body == "do not touch"

      Project.close(project)
    end

    test "reviewer runs the review stage without fs.write", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["catalog", "fs.read", "sequence", "store"]

      [agents.worker]
      depth = 1
      text = "I am the worker."
      tools = ["comment", "continue", "done", "end", "fs.read", "fs.write"]

      [agents.reviewer]
      depth = 1
      workflow_only = true
      text = "You are the reviewer."
      tools = ["comment", "continue", "done", "end", "fs.read", "notify"]

      [workflows.delivery]
      steps = [
        { name = "to_do", agent = "worker" },
        { name = "review", agent = "reviewer", deny = ["fs.write"] },
      ]

      [policy.depth.1]
      workflow = "delivery"
      """)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "You are the reviewer." ->
            call.("done", %{"report" => "reviewed"})
            {:ok, "unused"}

          assembled =~ "I am the worker." ->
            call.("done", %{"report" => "done"})
            {:ok, "unused"}

          assembled =~ "## Last comment\nopened" ->
            delegate_one(call, "Sub task", "do this")
            {:ok, "unused"}

          assembled =~ "## Work" ->
            call.("end", %{})

          true ->
            create_root(call, "Ship it")
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Ship it please"], dir)

      project = open_project(dir)

      assert {:ok, [reviewer_run]} =
               Query.all(project.conn, "SELECT * FROM runs WHERE agent = 'reviewer'")

      assert reviewer_run.depth == "1"
      assert reviewer_run.via == "continue"

      tools = Jason.decode!(reviewer_run.tools)
      assert "read" in tools
      assert "comment" in tools
      refute "write" in tools
      refute "edit" in tools

      assert {:ok, assembled} =
               Query.one(project.conn, "SELECT * FROM prompts WHERE id = ?", [
                 reviewer_run.prompt_id
               ])

      assert assembled.body =~ "## Last comment\ndone"
      refute assembled.body =~ "- write:"

      assert {:ok, works} = Query.all(project.conn, "SELECT * FROM works ORDER BY created_at")
      [parent, child] = works
      assert child.state == "done"
      assert parent.state == "open"

      Project.close(project)
    end

    test "workflow off: reviewer is absent", %{dir: dir} do
      write_config(dir, """
      [agents.concierge]
      depth = 0
      text = "I am the concierge."
      tools = ["work", "delegate", "comment", "end"]

      [agents.worker]
      depth = 1
      text = "I am the worker."
      tools = ["comment"]

      [agents.reviewer]
      depth = 1
      workflow_only = true
      text = "You are the reviewer."
      tools = ["comment"]
      """)

      model = fn assembled, _tools, call ->
        cond do
          assembled =~ "I am the worker." ->
            {:ok, "done"}

          assembled =~ "## Last comment\nopened" ->
            delegate_one(call, "Sub task", "do this")
            {:ok, "unused"}

          assembled =~ "## Work" ->
            call.("end", %{})

          true ->
            create_root(call, "Ship it")
            {:ok, "unused"}
        end
      end

      Fixtures.use_model(dir, model)

      assert {:ok, ""} = CLI.run(["send", "Ship it please"], dir)

      project = open_project(dir)

      assert {:ok, [child_run]} =
               Query.all(project.conn, "SELECT * FROM runs WHERE agent = 'worker'")

      assert child_run.depth == "1"

      assert {:ok, []} = Query.all(project.conn, "SELECT * FROM runs WHERE agent = 'reviewer'")

      Project.close(project)
    end
  end
end
