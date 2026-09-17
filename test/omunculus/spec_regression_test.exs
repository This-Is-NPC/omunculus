defmodule Omunculus.SpecRegressionTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Ceiling, CLI, Config, Fixtures, Id, Project, Run, Store}
  alias Omunculus.Store.Query

  @config """
  [execution]
  backend = "bubblewrap"
  runtimes = ["/usr"]
  environment = ["LANG", "LC_ALL", "TERM"]
  timeout_ms = 30000
  max_output_bytes = 1048576
  max_concurrent = 4
  max_queue = 64
  queue_timeout_ms = 30000
  resources = ["sandbox.write", "sandbox.network"]

  [execution.sandbox]
  script = #{Jason.encode!(Application.app_dir(:omunculus, "priv/sandbox.js"))}
  command = ["deno", "run", "--no-config", "--no-lock", "--no-prompt", "--cached-only", "--deny-read", "--deny-write", "--deny-net", "--deny-env", "--deny-run", "--deny-ffi", "--deny-sys", "--deny-import"]
  runner = 'input=$1; errors=$2; status=$3; shift 3; "$@" < "$input" 2> "$errors"; result=$?; printf %s "$result" > "$status"; exit "$result"'
  exec = 'exec "$@"'

  [store]
  path = ".omunculus/store.sqlite3"

  [models.fake]
  api = "module"
  module = "Omunculus.Model.Fake"

  [agents.concierge]
  depth = 0
  model = "fake"
  text = "concierge"
  tools = ["work", "comment", "reply", "request_access", "notify", "read", "write", "sandbox.network"]
  [agents.worker]
  depth = 1
  model = "fake"
  text = "worker"
  tools = ["comment", "request_access", "read"]
  human = ["write"]
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "omunculus-spec-" <> Id.new())
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "omunculus.toml"), @config <> "\n" <> Fixtures.tools_table(dir))
    {:ok, project} = Fixtures.open_project(dir)

    on_exit(fn ->
      Project.close(project)
      File.rm_rf!(dir)
    end)

    %{project: project, dir: dir}
  end

  defp opening(work_id \\ nil, overrides \\ %{}),
    do:
      Map.merge(
        %{prompt_id: nil, work_id: work_id, request_id: nil, via: nil, agent: nil},
        overrides
      )

  defp write_config(project, text) do
    body =
      if String.contains?(text, "[tools]"),
        do: text,
        else: text <> "\n" <> Fixtures.tools_table(project.dir)

    File.write!(Path.join(project.dir, "omunculus.toml"), body)
  end

  defp hook(project, name, event, emits \\ [], agent \\ nil) do
    dir = Path.join([project.dir, "tools", name])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "hook.toml"), """
    name = "#{name}"
    kind = "hook"
    events = ["#{event}"]
    command = ["./run"]
    #{if agent, do: "agent = \"#{agent}\"", else: ""}
    """)

    File.write!(
      Path.join(dir, "run"),
      "#!/bin/sh\ncat >/dev/null\nprintf '%s' '" <>
        Jason.encode!(%{ok: true, output: "reacted", emit: emits}) <> "'\n"
    )

    File.chmod!(Path.join(dir, "run"), 0o755)
  end

  test "unknown emit fields roll back the entire batch and its tool event", %{project: p} do
    work = Fixtures.insert(p.conn, :works)
    {:ok, config} = Config.load(p.config_path)
    ctx = %{run_id: nil, work_id: work, author: "human", agent: nil, config: config, groups: %{}}

    emits = [
      %{"type" => "comment", "body" => %{"work_id" => work, "body" => "valid"}},
      %{
        "type" => "comment",
        "body" => %{"work_id" => work, "body" => "invalid", "created_at" => "forged"}
      }
    ]

    assert {:error, {:invalid_emit, "comment", {:unknown_field, "created_at"}}} =
             Store.record_tool(p.conn, nil, %{name: "comment"}, emits, ctx)

    assert {:ok, []} = Store.replay(p.conn, :project)
    assert {:ok, []} = Store.view(p.conn, "comments.work", work)
  end

  test "sealed child request goes to the human even when the parent has authority", %{project: p} do
    parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})
    child = Fixtures.insert(p.conn, :works, %{assignee: "worker", parent_id: parent})

    Fixtures.use_model(p, fn _, _, call ->
      call.("request_access", %{
        "kind" => "tool",
        "name" => "write",
        "reason" => "write report"
      })

      flunk("request must end the run")
    end)

    assert {:ok, _} =
             Run.open(p, opening(child))

    assert {:ok, [%{arbiter: "human", status: "waiting_human"}]} =
             Query.all(p.conn, "SELECT * FROM requests")

    assert {:ok, [_]} = Query.all(p.conn, "SELECT * FROM runs")
  end

  test "an agent cannot reply to a human request or make a permanent grant", %{project: p} do
    requester = Fixtures.insert(p.conn, :runs)
    request = Fixtures.insert(p.conn, :requests, %{run_id: requester})

    Fixtures.use_model(p, fn _, _, call ->
      for scope <- [nil, "agent"] do
        args = %{"request_id" => request, "decision" => "grant", "body" => "approve"}
        args = if scope, do: Map.put(args, "scope", scope), else: args
        assert {:error, {:reply, :not_arbiter}} = call.("reply", args)
      end

      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, opening())

    assert {:ok, %{status: "waiting_human"}} = Store.view(p.conn, "request", request)
  end

  test "arbiter receives request id and grant ends its run before resuming the child", %{
    project: p
  } do
    parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})

    child =
      Fixtures.insert(p.conn, :works, %{
        assignee: "worker",
        parent_id: parent,
        state: "waiting",
        waiting: "access"
      })

    requester =
      Fixtures.insert(p.conn, :runs, %{
        agent: "worker",
        depth: "1",
        work_id: child,
        status: "done"
      })

    request =
      Fixtures.insert(p.conn, :requests, %{
        agent: "worker",
        run_id: requester,
        work_id: child,
        arbiter: "concierge",
        status: "waiting_agent"
      })

    Fixtures.use_model(p, fn assembled, tools, call ->
      if String.starts_with?(assembled, "concierge") do
        assert assembled =~ request

        call.("reply", %{
          "request_id" => request,
          "decision" => "grant",
          "body" => "approved"
        })

        flunk("grant must end the arbiter's run")
      else
        assert Enum.any?(tools, &(&1.name == "write"))
        {:ok, "resumed"}
      end
    end)

    assert {:ok, _} =
             Run.open(p, opening(parent, %{request_id: request}))

    assert {:ok, %{status: "closed"}} = Store.view(p.conn, "request", request)
    assert {:ok, events} = Store.replay(p.conn, {:request, request})
    assert Enum.any?(events, &(&1.type == "start-run"))
    assert Enum.any?(events, &(&1.type == "end-run"))
    assert Enum.any?(events, &(&1.type == "model"))
  end

  test "missing tool is blocked and absent from the run's tools", %{project: p} do
    write_config(p, String.replace(@config, "\"work\",", "\"missing_tool\", \"work\","))

    Fixtures.use_model(p, fn _, tools, call ->
      refute Enum.any?(tools, &(&1.name == "missing_tool"))

      call.("request_access", %{
        "kind" => "tool",
        "name" => "missing_tool",
        "reason" => "test"
      })

      flunk("blocked request ends the run")
    end)

    assert {:ok, run} =
             Run.open(p, opening())

    refute "missing_tool" in Jason.decode!(run.tools)
    assert {:ok, []} = Query.all(p.conn, "SELECT * FROM requests")
    assert {:ok, events} = Store.replay(p.conn, {:run, run.id})
    assert Enum.any?(events, &(&1.type == "deny"))
  end

  test "permanent grant clears human and negotiable in the chosen layer", %{project: p} do
    write_config(p, @config <> "negotiable = [\"write\"]\n")
    assert :ok = Config.grant(p.config_path, {:agent, "worker"}, "write")
    {:ok, config} = Config.load(p.config_path)

    snapshot =
      Ceiling.mount(
        config,
        %{agent: "worker", depth: 1, grants: [], stage: nil, workspace: nil, groups: %{}},
        ["write"]
      )

    assert Ceiling.classify(snapshot, "write", "tool") == "have"
    assert config.agents["worker"].ceiling.human == []
    assert config.agents["worker"].ceiling.negotiable == []
  end

  test "ancestor grant overrides an implicit allowlist block but never explicit deny", %{
    project: p
  } do
    config_text = @config <> "mode = \"allowlist\"\n"
    write_config(p, config_text)

    parent =
      Fixtures.insert(p.conn, :works, %{assignee: "concierge", grants: Jason.encode!(["write"])})

    child = Fixtures.insert(p.conn, :works, %{assignee: "worker", parent_id: parent})
    Fixtures.use_model(p, fn _, _, _ -> {:ok, "done"} end)
    assert {:ok, run} = Run.open(p, opening(child))
    assert "write" in Jason.decode!(run.tools)
    write_config(p, config_text <> "deny = [\"write\"]\n")
    Fixtures.use_model(p, fn _, _, _ -> {:ok, "done"} end)
    assert {:ok, run} = Run.open(p, opening(child))
    refute "write" in Jason.decode!(run.tools)
  end

  test "path deny and a directory grant are applied by filesystem tools", %{project: p} do
    write_config(
      p,
      String.replace(@config, "[agents.worker]", "deny = [\"./secret\"]\n[agents.worker]")
    )

    File.write!(Path.join(p.dir, "secret"), "SECRET MARKER")
    outside = Path.join(System.tmp_dir!(), "omunculus-granted-" <> Id.new())
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "report"), "granted report")
    File.ln_s!(outside, Path.join(p.dir, "escape"))

    Fixtures.use_model(p, fn _, _, call ->
      assert {:ok, error} = call.("read", %{"path" => "./secret"})
      refute error =~ "SECRET MARKER"
      assert error =~ "path outside roots"
      assert {:ok, error} = call.("read", %{"path" => "escape/report"})
      assert error =~ "path outside roots"

      assert {:ok, error} =
               call.("write", %{"path" => "escape/new", "content" => "forbidden"})

      assert error =~ "path outside roots"
      refute File.exists?(Path.join(outside, "new"))
      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, opening())

    work = Fixtures.insert(p.conn, :works, %{grants: Jason.encode!([outside])})

    Fixtures.use_model(p, fn _, _, call ->
      assert {:ok, "granted report"} =
               call.("read", %{"path" => Path.join(outside, "report")})

      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, opening(work))
  end

  test "CLI comments on an inbox without creating a request", %{project: p} do
    inbox = Fixtures.insert(p.conn, :inbox)

    assert {:ok, ""} =
             CLI.run(
               ["comment", "noted", "--inbox_id", inbox],
               p.dir
             )

    assert {:ok, [%{body: "noted", author: "human"}]} =
             Store.view(p.conn, "comments.inbox", inbox)

    assert {:ok, []} = Query.all(p.conn, "SELECT * FROM requests")
  end

  test "start-run, model, tool and end-run each trigger their hooks", %{project: p} do
    for event <- ~w(start-run model tool end-run), do: hook(p, "watch-" <> event, event)
    work = Fixtures.insert(p.conn, :works)

    Fixtures.use_model(p, fn _, _, call ->
      assert {:ok, _} = call.("comment", %{"body" => "note"})
      {:ok, "done"}
    end)

    assert {:ok, run} =
             Run.open(p, opening(work))

    {:ok, events} = Store.replay(p.conn, {:run, run.id})
    calls = for %{type: "tool", body: body} <- events, do: Jason.decode!(body)["name"]
    for event <- ~w(start-run model tool end-run), do: assert(("watch-" <> event) in calls)
    {:ok, work_events} = Store.replay(p.conn, {:work, work})
    assert Enum.map(work_events, & &1.id) == Enum.map(events, & &1.id)
  end

  test "a hook cannot advance the workflow without an agent run", %{project: p} do
    write_config(
      p,
      @config <>
        """
        [policy]
        workflow = "delivery"
        [workflows.delivery]
        steps = [{name = "first", agent = "concierge"}, {name = "second", agent = "concierge"}]
        """
    )

    hook(p, "on-notify", "notify", [%{type: "continue", body: %{}}])
    work = Fixtures.insert(p.conn, :works, %{stage: "first", assignee: "concierge"})

    Fixtures.use_model(p, fn _, _, call ->
      assert {:error, {:hook, {:cannot_sequence, "continue"}}} =
               call.("notify", %{"body" => "notice"})

      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, opening(work))

    assert {:ok, %{stage: "first"}} = Store.view(p.conn, "work", work)
    assert {:ok, []} = Query.all(p.conn, "SELECT * FROM events WHERE type = 'continue'")
  end

  test "creating a workflow work ends the old run and mounts its first agent and ceiling", %{
    project: p
  } do
    write_config(
      p,
      @config <>
        """
        [policy]
        workflow = "delivery"
        [workflows.delivery]
        steps = [{name = "first", agent = "worker", deny = ["write"]}]
        """
    )

    Fixtures.use_model(p, fn assembled, tools, call ->
      if assembled =~ "## Work" do
        assert String.starts_with?(assembled, "worker")
        refute assembled =~ "## Message"
        refute Enum.any?(tools, &(&1.name == "write"))
        {:ok, "first stage"}
      else
        call.("work", %{"title" => "stage handoff"})
        flunk("creation must end the old run")
      end
    end)

    assert {:ok, _} =
             Run.open(p, opening())

    assert {:ok, [work]} = Query.all(p.conn, "SELECT * FROM works")
    assert work.stage == "first"
    assert work.assignee == "worker"
    assert {:ok, runs} = Query.all(p.conn, "SELECT * FROM runs")
    assert length(runs) == 2
    assert {:ok, events} = Store.replay(p.conn, {:work, work.id})
    assert Enum.count(events, &(&1.type == "start-run")) == 2
    assert Enum.count(events, &(&1.type == "end-run")) == 2
    assert Enum.any?(events, &(&1.type == "model"))
  end

  test "named reaction respects the work's stage ceiling and workflow-only restriction", %{
    project: p
  } do
    write_config(
      p,
      @config <>
        """
        [agents.reviewer]
        depth = 1
        model = "fake"
        text = "reviewer"
        workflow_only = true
        [workflows.delivery]
        steps = [{name = "review", agent = "worker", deny = ["write"]}]
        [policy]
        workflow = "delivery"
        """
    )

    work = Fixtures.insert(p.conn, :works, %{stage: "review"})

    Fixtures.use_model(p, fn _, tools, call ->
      refute Enum.any?(tools, &(&1.name == "write"))
      assert {:error, {:not_allowed, "write"}} = call.("write", %{})
      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, opening(work, %{agent: "concierge", via: "reaction"}))

    write_config(
      p,
      @config <>
        """
        [agents.reviewer]
        depth = 1
        model = "fake"
        text = "reviewer"
        workflow_only = true
        """
    )

    Fixtures.use_model(p, fn _, _, _ ->
      flunk("reviewer must not run")
    end)

    assert {:error, {:workflow_off, "reviewer"}} =
             Run.open(p, opening(nil, %{agent: "reviewer"}))
  end

  test "model messages are recorded before terminal actions", %{project: p} do
    Fixtures.use_model(p, fn _, _, call, record ->
      :ok = record.(%{content: "I need access", tool_calls: [%{name: "request_access"}]})

      call.("request_access", %{
        "kind" => "path",
        "name" => "./secret",
        "reason" => "read report"
      })

      flunk("request ends run")
    end)

    assert {:ok, run} =
             Run.open(p, opening())

    assert {:ok, events} = Store.replay(p.conn, {:run, run.id})
    assert Enum.map(events, & &1.type) == ~w(start-run model tool request tool end-run)
    assert Enum.find(events, &(&1.type == "model")).body =~ "I need access"
  end

  test "inbox hook's agent sees only that inbox's complete thread", %{project: p} do
    hook(p, "on-notify", "notify", [], "worker")

    Fixtures.use_model(p, fn assembled, _, call ->
      if String.starts_with?(assembled, "concierge") do
        assert {:ok, _} = call.("notify", %{"body" => "standalone notice"})
        {:ok, "notified"}
      else
        assert assembled =~ "## Inbox\n"
        assert assembled =~ "standalone notice"
        {:ok, "observed"}
      end
    end)

    assert {:ok, _} =
             Run.open(p, opening())

    assert {:ok, [%{id: inbox}]} = Query.all(p.conn, "SELECT * FROM inbox")
    assert {:ok, events} = Store.replay(p.conn, {:inbox, inbox})
    assert Enum.any?(events, &(&1.type == "start-run"))
    assert Enum.any?(events, &(&1.type == "model"))
    assert Enum.any?(events, &(&1.type == "end-run"))
  end
end
