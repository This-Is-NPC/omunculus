defmodule Omunculus.SpecRegressionTest do
  @human Omunculus.Fixtures.defaults(:requests).arbiter
  @concierge Jason.encode!(Omunculus.Participant.agent("concierge"))
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Out
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
  tools = ["work", "comment", "grant", "reply", "request_access", "notify", "read", "write", "sandbox.network", "end"]
  [agents.worker]
  depth = 1
  model = "fake"
  text = "worker"
  tools = ["comment", "request_access", "read", "end"]
  human = ["write"]
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "omunculus-spec-" <> Id.new())
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "omunculus.toml"),
      ensure_policy(@config <> "\n" <> Fixtures.tools_table(dir))
    )

    project = Fixtures.open_project(dir)

    on_exit(fn ->
      Project.close(project)
      File.rm_rf!(dir)
    end)

    %{project: project, dir: dir}
  end

  defp ensure_policy(body) do
    Enum.reduce([{"assemble", ~s("assemble")}, {"max_retries", "0"}], body, fn {key, value},
                                                                               body ->
      cond do
        String.contains?(body, key <> " =") ->
          body

        String.contains?(body, "[policy]") ->
          String.replace(body, "[policy]", "[policy]\n#{key} = #{value}", global: false)

        true ->
          body <> "\n[policy]\n#{key} = #{value}\n"
      end
    end)
  end

  defp write_config(project, text) do
    body =
      if String.contains?(text, "[tools]"),
        do: text,
        else: text <> "\n" <> Fixtures.tools_table(project.dir)

    File.write!(Path.join(project.dir, "omunculus.toml"), ensure_policy(body))
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
             Store.record_tools(p.conn, nil, [{%{name: "comment"}, emits}], ctx)

    assert {:ok, []} = Store.replay(p.conn, :project)
    assert {:ok, []} = Store.comments(p.conn, :work, work)
  end

  test "sealed child request goes to the human even when the parent has authority", %{project: p} do
    parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})
    child = Fixtures.insert(p.conn, :works, %{assignee: "worker", parent_id: parent})

    Fixtures.use_model(p, fn _, _, call ->
      call.("request_access", %{
        "report" => "blocked",
        "access" => [%{"kind" => "tool", "name" => "write"}],
        "reason" => "write report"
      })

      flunk("request_access must end the run")
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, child))

    assert {:ok, [%{arbiter: @human, status: "pending"}]} =
             Query.all(p.conn, "SELECT * FROM requests")

    assert {:ok, [_]} = Query.all(p.conn, "SELECT * FROM runs")
  end

  test "an agent cannot reply to a human request", %{project: p} do
    requester = Fixtures.insert(p.conn, :runs)
    request = Fixtures.insert(p.conn, :requests, %{run_id: requester})

    Fixtures.use_model(p, fn _, _, call ->
      for option <- ["grant", "deny"] do
        args = %{"request_id" => request, "option" => option, "body" => "approve"}
        assert call.("reply", args) == {:ok, Out.refused({:reply, :not_arbiter})}
      end

      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil))

    assert {:ok, %{status: "pending"}} = Store.view(p.conn, "request", request)
  end

  test "an arbiter agent cannot make a permanent grant and the reply writes nothing", %{
    project: p
  } do
    {parent, child, request} =
      agent_request(p, %{
        "grant_agent" => [
          %{
            "name" => "grant",
            "args" => %{"kind" => "tool", "name" => "write", "scope" => "agent"}
          }
        ]
      })

    Fixtures.use_model(p, fn _, _, call ->
      args = %{"request_id" => request, "option" => "grant_agent", "body" => "forever"}
      assert call.("reply", args) == {:ok, Out.refused({:grant, :not_human})}
      {:ok, "done"}
    end)

    assert {:ok, _} = Run.open(p, Fixtures.opening(nil, parent, %{request_id: request}))
    # Its run closed without a reply, so the request is the person's now.
    assert {:ok, %{status: "pending", arbiter: @human}} =
             Store.view(p.conn, "request", request)

    assert {:ok, events} = Store.replay(p.conn, :project)
    assert %{body: body} = Enum.find(events, &(&1.type == "escalate"))
    assert Jason.decode!(body) == %{"from" => "concierge"}
    assert Enum.any?(events, &(&1.type == "notify"))
    assert {:ok, %{state: "waiting", grants: nil}} = Store.view(p.conn, "work", child)
    {:ok, config} = Config.load(p.config_path)
    refute "write" in config.agents["worker"].ceiling.granted
  end

  test "an option call outside reply's chains fails the reply and writes nothing", %{
    project: p
  } do
    {parent, child, request} =
      agent_request(p, %{"note" => [%{"name" => "comment", "args" => %{"body" => "x"}}]})

    Fixtures.use_model(p, fn _, _, call ->
      args = %{"request_id" => request, "option" => "note", "body" => "noted"}
      assert {:ok, output} = call.("reply", args)
      assert output =~ "chain failed at comment"
      {:ok, "done"}
    end)

    assert {:ok, _} = Run.open(p, Fixtures.opening(nil, parent, %{request_id: request}))
    assert {:ok, %{status: "pending"}} = Store.view(p.conn, "request", request)
    assert {:ok, %{state: "waiting"}} = Store.view(p.conn, "work", child)
  end

  # A child of a concierge work, waiting on a request from its run whose
  # arbiter is the concierge.
  defp agent_request(p, options \\ %{}) do
    parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})

    child =
      Fixtures.insert(p.conn, :works, %{
        assignee: "worker",
        parent_id: parent,
        state: "waiting",
        waiting: "request"
      })

    requester_run =
      Fixtures.open_run(p.conn, %{
        agent: "worker",
        depth: 1,
        work_id: child,
        ceiling: %{
          have: ["comment"],
          askable: ["write"],
          sealed: [],
          blocked: [],
          uncited: "askable"
        }
      })

    {:ok, _} = Store.close_run(p.conn, requester_run.id)
    requester = requester_run.id

    default = Jason.decode!(Fixtures.defaults(:requests).options)

    request =
      Fixtures.insert(p.conn, :requests, %{
        requester: Jason.encode!(Omunculus.Participant.agent("worker")),
        run_id: requester,
        work_id: child,
        arbiter: @concierge,
        status: "pending",
        options: Jason.encode!(Map.merge(default, options))
      })

    :ok = Query.exec(p.conn, "UPDATE works SET waiting_for = ? WHERE id = ?", [request, child])
    {parent, child, request}
  end

  test "arbiter receives request id and its end closes the run before resuming the child", %{
    project: p
  } do
    {parent, _child, request} = agent_request(p)

    Fixtures.use_model(p, fn assembled, tools, call ->
      if String.starts_with?(assembled, "concierge") do
        assert assembled =~ request

        call.("reply", %{
          "request_id" => request,
          "option" => "grant",
          "body" => "approved"
        })

        call.("end", %{})
        flunk("end must end the arbiter's run")
      else
        assert Enum.any?(tools, &(&1.name == "write"))
        {:ok, "resumed"}
      end
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, parent, %{request_id: request}))

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

      assert call.("request_access", %{
               "report" => "blocked",
               "access" => [%{"kind" => "tool", "name" => "missing_tool"}],
               "reason" => "test"
             }) == {:ok, Out.refused({:request, {:blocked, "missing_tool"}})}

      {:ok, "went on"}
    end)

    assert {:ok, run} =
             Run.open(p, Fixtures.opening(nil))

    refute "missing_tool" in Jason.decode!(run.tools)
    assert {:ok, []} = Query.all(p.conn, "SELECT * FROM requests")
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
    assert {:ok, run} = Run.open(p, Fixtures.opening(nil, child))
    assert "write" in Jason.decode!(run.tools)
    write_config(p, config_text <> "deny = [\"write\"]\n")
    Fixtures.use_model(p, fn _, _, _ -> {:ok, "done"} end)
    # The first run broke the child, so only a named agent opens a run on it.
    assert {:ok, run} = Run.open(p, Fixtures.opening(nil, child, %{agent: "worker"}))
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
             Run.open(p, Fixtures.opening(nil))

    work = Fixtures.insert(p.conn, :works, %{grants: Jason.encode!([outside])})

    Fixtures.use_model(p, fn _, _, call ->
      assert {:ok, "granted report"} =
               call.("read", %{"path" => Path.join(outside, "report")})

      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, work))
  end

  test "CLI comments on an inbox without creating a request", %{project: p} do
    inbox = Fixtures.insert(p.conn, :inbox)

    assert {:ok, ""} =
             CLI.run(
               ["comment", "noted", "--inbox_id", inbox],
               p.dir
             )

    assert {:ok, [%{body: "noted", author: "human"}]} =
             Store.comments(p.conn, :inbox, inbox)

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
             Run.open(p, Fixtures.opening(nil, work))

    {:ok, events} = Store.replay(p.conn, {:run, run.id})
    calls = for %{type: "tool", body: body} <- events, do: Jason.decode!(body)["name"]
    for event <- ~w(start-run model tool end-run), do: assert(("watch-" <> event) in calls)
    {:ok, work_events} = Store.replay(p.conn, {:work, work})
    assert Enum.map(work_events, & &1.id) == Enum.map(events, & &1.id)
  end

  test "a hook continue advances the workflow when the sequence is valid", %{project: p} do
    write_config(
      p,
      @config <>
        """
        [policy]
        workflows = ["delivery"]
        [workflows.delivery]
        steps = [{name = "first", agent = "concierge"}, {name = "second", agent = "concierge"}]
        """
    )

    hook(p, "on-notify", "notify", [%{type: "continue", body: %{}}])

    work =
      Fixtures.insert(p.conn, :works, %{
        workflow: "delivery",
        stage: "first",
        assignee: "concierge"
      })

    {:ok, n} = Agent.start_link(fn -> 0 end)

    Fixtures.use_model(p, fn _, _, call ->
      case Agent.get_and_update(n, fn i -> {i, i + 1} end) do
        0 ->
          assert {:ok, _} = call.("notify", %{"body" => "notice"})
          assert {:ok, %{stage: "second"}} = Store.view(p.conn, "work", work)
          call.("end", %{})
          flunk("end must end the run")

        _ ->
          {:ok, "done"}
      end
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, work))

    assert {:ok, %{stage: "second"}} = Store.view(p.conn, "work", work)
    assert {:ok, [_continue]} = Query.all(p.conn, "SELECT * FROM events WHERE type = 'continue'")
  end

  test "on-continue runs in the unroll while hooks of end wait for the close", %{
    project: p
  } do
    write_config(
      p,
      String.replace(
        @config,
        ~s("sandbox.network", "end"]),
        ~s("sandbox.network", "end", "continue", "done"])
      ) <>
        """
        [policy]
        workflows = ["delivery"]
        [workflows.delivery]
        steps = [{name = "first", agent = "concierge"}, {name = "second", agent = "concierge"}]
        """
    )

    hook(p, "on-continue", "continue")
    hook(p, "on-end", "end")

    work =
      Fixtures.insert(p.conn, :works, %{
        workflow: "delivery",
        stage: "first",
        assignee: "concierge"
      })

    {:ok, n} = Agent.start_link(fn -> 0 end)

    Fixtures.use_model(p, fn _, _, call ->
      case Agent.get_and_update(n, fn i -> {i, i + 1} end) do
        0 ->
          call.("done", %{"report" => "first done"})
          flunk("done must end the run")

        _ ->
          {:ok, "later"}
      end
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, work))

    assert {:ok, %{stage: "second"}} = Store.view(p.conn, "work", work)
    assert {:ok, events} = Store.replay(p.conn, {:work, work})
    types = Enum.map(events, & &1.type)

    continue_at = Enum.find_index(types, &(&1 == "continue"))
    end_run_at = Enum.find_index(types, &(&1 == "end-run"))
    starts = Enum.with_index(types) |> Enum.filter(fn {type, _} -> type == "start-run" end)
    assert length(starts) == 2
    {_type, second_start} = List.last(starts)
    assert continue_at < end_run_at
    assert end_run_at < second_start

    hook_at = fn name ->
      Enum.find_index(events, fn event ->
        event.type == "tool" and Jason.decode!(event.body)["name"] == name
      end)
    end

    assert continue_at < hook_at.("on-continue")
    assert hook_at.("on-continue") < end_run_at
    # The next run opens concurrently with the hooks of end.
    assert end_run_at < hook_at.("on-end")
  end

  test "work with then = [] does not end the run: the delegate hook runs at once and the child opens while the parent's run goes on",
       %{project: p} do
    write_config(
      p,
      String.replace(
        @config,
        ~s("sandbox.network", "end"]),
        ~s("sandbox.network", "end", "delegate"]\noverrides.work.then = [])
      )
    )

    hook(p, "on-delegate", "delegate")
    parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})
    test_pid = self()

    Fixtures.use_model(p, fn assembled, _, call ->
      if String.starts_with?(assembled, "concierge") do
        assert {:ok, _} =
                 call.("work", %{
                   "report" => "delegated",
                   "works" => [%{"title" => "child", "goal" => "child goal"}]
                 })

        # The parent's model goes on only once the child's run has started.
        assert_receive :child_started, 5_000
        assert {:ok, _} = call.("comment", %{"body" => "still here"})
        call.("end", %{})
        flunk("end must end the run")
      else
        send(test_pid, :child_started)
        call.("end", %{})
      end
    end)

    assert {:ok, run} = Run.open(p, Fixtures.opening(nil, parent))

    assert {:ok, events} = Store.replay(p.conn, {:run, run.id})
    types = Enum.map(events, & &1.type)
    delegate_at = Enum.find_index(types, &(&1 == "delegate"))
    assert Jason.decode!(Enum.at(events, delegate_at + 1).body)["name"] == "on-delegate"
    assert "comment" in Enum.drop(types, delegate_at)
    assert Enum.take(types, -2) == ["end", "end-run"]

    assert {:ok, [child]} = Query.all(p.conn, "SELECT * FROM works WHERE parent_id = ?", [parent])

    assert {:ok, [child_run]} =
             Query.all(p.conn, "SELECT * FROM runs WHERE work_id = ?", [child.id])

    assert child_run.via == "delegate"

    assert {:ok, [parent_end]} =
             Query.all(p.conn, "SELECT * FROM events WHERE type = 'end-run' AND run_id = ?", [
               run.id
             ])

    assert {:ok, child_start} =
             Query.one(p.conn, "SELECT * FROM events WHERE id = ?", [child_run.event_id])

    assert child_start.sequence < parent_end.sequence
    assert {:ok, %{state: "open"}} = Store.view(p.conn, "work", child.id)
    assert {:ok, %{state: "waiting"}} = Store.view(p.conn, "work", parent)
  end

  test "a child that ends with done or break is not retried",
       %{project: p} do
    write_config(
      p,
      String.replace(
        @config,
        ~s(tools = ["comment", "request_access", "read", "end"]),
        ~s(tools = ["comment", "request_access", "read", "end", "continue", "done", "break"])
      )
    )

    for action <- ["done", "break"] do
      parent = Fixtures.insert(p.conn, :works, %{assignee: "concierge"})
      child = Fixtures.insert(p.conn, :works, %{assignee: "worker", parent_id: parent})

      Fixtures.use_model(p, fn assembled, _, call ->
        if String.starts_with?(assembled, "worker") do
          call.(action, %{"report" => "stopping"})
          flunk("#{action} must end the run")
        else
          {:ok, "parent"}
        end
      end)

      assert {:ok, _run} = Run.open(p, Fixtures.opening(nil, child))

      assert {:ok, %{state: state}} = Store.view(p.conn, "work", child)
      assert state == if(action == "done", do: "done", else: "waiting")

      assert {:ok, [_one_run]} =
               Query.all(p.conn, "SELECT * FROM runs WHERE work_id = ?", [child])
    end
  end

  test "a workflow work created by work opens with its first agent and ceiling", %{
    project: p
  } do
    write_config(
      p,
      @config <>
        """
        [policy]
        workflows = ["delivery"]
        [workflows.delivery]
        steps = [{name = "first", agent = "worker", deny = ["write"]}]
        """
    )

    Fixtures.use_model(p, fn assembled, tools, call ->
      if assembled =~ "## Work\n" do
        assert String.starts_with?(assembled, "worker")
        refute assembled =~ "## Message"
        refute Enum.any?(tools, &(&1.name == "write"))
        {:ok, "first stage"}
      else
        call.("work", %{
          "report" => "handed off",
          "works" => [%{"title" => "stage handoff", "goal" => "stage handoff"}]
        })

        flunk("work must end the old run")
      end
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil))

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
        workflows = ["delivery"]
        """
    )

    work = Fixtures.insert(p.conn, :works, %{workflow: "delivery", stage: "review"})

    Fixtures.use_model(p, fn _, tools, call ->
      refute Enum.any?(tools, &(&1.name == "write"))
      assert call.("write", %{}) == {:error, Out.not_yours("write")}
      {:ok, "done"}
    end)

    assert {:ok, _} =
             Run.open(p, Fixtures.opening(nil, work, %{agent: "concierge", via: "reaction"}))

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
             Run.open(p, Fixtures.opening(nil, nil, %{agent: "reviewer"}))
  end

  test "model messages are recorded before the actions they call", %{project: p} do
    Fixtures.use_model(p, fn _, _, call, record ->
      :ok = record.(%{content: "I need access", tool_calls: [%{name: "request_access"}]})

      call.("request_access", %{
        "report" => "blocked",
        "access" => [%{"kind" => "path", "name" => "./secret"}],
        "reason" => "read report"
      })

      flunk("request_access must end the run")
    end)

    assert {:ok, run} =
             Run.open(p, Fixtures.opening(nil))

    assert {:ok, events} = Store.replay(p.conn, {:run, run.id})

    assert Enum.map(events, & &1.type) ==
             ~w(start-run tool model tool request tool end tool end-run)

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
             Run.open(p, Fixtures.opening(nil))

    assert {:ok, [%{id: inbox}]} = Query.all(p.conn, "SELECT * FROM inbox")
    assert {:ok, events} = Store.replay(p.conn, {:inbox, inbox})
    assert Enum.any?(events, &(&1.type == "start-run"))
    assert Enum.any?(events, &(&1.type == "model"))
    assert Enum.any?(events, &(&1.type == "end-run"))
  end
end
