defmodule Omunculus.Jobs.SchedulerTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Cycle, Fixtures, Jobs, Project}
  alias Omunculus.Jobs.{Fire, Preview, Scheduler}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [open_project: 1, write_config: 2]

  defmodule Gate do
    @moduledoc false
    # A condition tool: answers whatever its `answer` argument says.
    def run(%{args: args}), do: %{"ok" => true, "output" => args["answer"], "emit" => []}
  end

  @jobs """
  [jobs]
  max_parallel = 2
  min_interval_minutes = 5
  max_jobs = 10
  missed = "skip"
  lateness_seconds = 60
  failures_before_pause = 2
  agent_may_create = false
  """

  @price %{"input" => 1.0, "output" => 2.0, "cache_write" => 0.0, "cache_read" => 0.0}

  setup do
    dir = Fixtures.tmp_dir()
    %{dir: dir}
  end

  # A project whose agent answers "all done" after 1000 tokens read and 500
  # written, or fails when told `fail`.
  defp setup_project(dir, jobs \\ @jobs) do
    write_gate(dir)

    write_config(dir, """
    [agents.keeper]
    depth = 0
    text = "I keep the project."
    tools = ["end"]

    #{jobs}
    """)

    Fixtures.use_model(dir, fn assembled, _tools, _call, record ->
      if assembled =~ "fail" do
        {:error, :the_model_is_down}
      else
        reply = %{
          "role" => "assistant",
          "model" => "scripted",
          "content" => "all done",
          "usage" => %{"prompt_tokens" => 1000, "completion_tokens" => 500}
        }

        :ok = record.(reply)
        {:ok, "all done"}
      end
    end)

    path = Fixtures.config_path(dir)
    data = Toml.decode_file!(path)

    File.write!(
      path,
      Omunculus.Config.Toml.encode(put_in(data, ["models", "scripted", "price"], @price))
    )
  end

  defp write_gate(dir) do
    tool = Path.join([dir, "tools", "gate"])
    File.mkdir_p!(tool)

    File.write!(Path.join(tool, "tool.toml"), """
    name = "gate"
    kind = "tool"
    triggers = ["cli", "chain"]
    description = "Answers what it is told."
    module = "#{inspect(Gate)}"

    [parameters]
    type = "object"
    """)
  end

  defp create(dir, name, extra \\ []) do
    args =
      [
        "--name",
        name,
        "--agent",
        "keeper",
        "--message",
        "hello",
        "--schedule",
        "every 5m",
        "--timezone",
        "UTC"
      ] ++
        Enum.flat_map(extra, fn {key, value} -> ["--#{key}", value] end)

    assert {:ok, _said} = CLI.run(["jobs", "create" | args], dir)
  end

  defp with_project(dir, fun) do
    project = open_project(dir)

    try do
      fun.(project)
    after
      Project.close(project)
    end
  end

  # The instant `minutes` and `seconds` after the job began counting.
  defp after_anchor(project, name, minutes, seconds \\ 10) do
    {:ok, job} = Jobs.get(project.conn, name)
    {:ok, anchor, _offset} = DateTime.from_iso8601(job["anchor"])
    DateTime.add(anchor, minutes * 60 + seconds)
  end

  # One tick of the scheduler at `now`, its fires run one after another.
  defp tick(project, now, boot? \\ false) do
    Cycle.run(project, nil, fn project ->
      {:ok, started} = Scheduler.plan(project, now, boot?)
      Enum.each(started, &(:ok = Fire.run(project, &1.job, &1.fire)))
      started
    end)
  end

  defp fires(project, name) do
    {:ok, fires} = Jobs.fires(project.conn, name)
    fires
  end

  defp states(project, name), do: project |> fires(name) |> Enum.map(& &1["state"])

  defp requests(project) do
    {:ok, rows} = Query.all(project.conn, "SELECT body FROM events WHERE type = 'request'")
    Enum.map(rows, &Jason.decode!(&1.body)["reason"])
  end

  test "a due fire runs end to end and is recorded with its cost", %{dir: dir} do
    setup_project(dir)
    create(dir, "morning", delivery: "owner_inbox")

    with_project(dir, fn project ->
      now = after_anchor(project, "morning", 5)
      assert [%{job: %{"name" => "morning"}}] = tick(project, now)

      assert [fire] = fires(project, "morning")
      assert fire["state"] == "succeeded"
      assert fire["message"] == "all done"
      assert fire["calls"] == 1
      assert fire["input_tokens"] == 1000
      assert fire["output_tokens"] == 500
      assert_in_delta fire["usd"], 0.002, 1.0e-9
      assert fire["duration_ms"] >= 0
      assert [run_id] = fire["run_ids"]

      # The run carries the loop guard: it came from a job.
      assert {:ok, %{via: "job"}} =
               Query.one(project.conn, "SELECT via FROM runs WHERE id = ?", [run_id])

      assert {:ok, [%{"text" => "all done", "unread" => true}]} =
               Jobs.messages(project.conn, "morning")

      assert {:ok, %{"fires" => %{"succeeded" => 1}}} = Jobs.get(project.conn, "morning")

      # The slot is taken: the same instant fires nothing more.
      assert [] = tick(project, now)
      assert length(fires(project, "morning")) == 1
    end)
  end

  test "a condition that says no skips the fire without a model", %{dir: dir} do
    setup_project(dir)

    create(dir, "gated",
      condition: "gate",
      condition_args: ~s({"answer": "{\\"run\\": false, \\"reason\\": \\"not paid\\"}"})
    )

    with_project(dir, fn project ->
      assert [] = tick(project, after_anchor(project, "gated", 5))
      assert [%{"state" => "skipped", "reason" => "not paid"}] = fires(project, "gated")

      assert {:ok, []} = Query.all(project.conn, "SELECT id FROM runs")
      assert {:ok, %{"state" => "active"}} = Jobs.get(project.conn, "gated")
    end)
  end

  test "a condition that says the entitlement is gone pauses the job and tells its owner", %{
    dir: dir
  } do
    setup_project(dir)

    create(dir, "plan",
      condition: "gate",
      condition_args:
        ~s({"answer": "{\\"run\\": false, \\"pause\\": true, \\"reason\\": \\"subscription cancelled\\"}"})
    )

    with_project(dir, fn project ->
      tick(project, after_anchor(project, "plan", 5))
      assert ["skipped"] = states(project, "plan")

      assert {:ok, %{"state" => "paused", "state_reason" => "subscription cancelled"}} =
               Jobs.get(project.conn, "plan")

      assert [notice] = requests(project)
      assert notice =~ "Job plan: paused: subscription cancelled"
    end)
  end

  test "a job is paused after the failures the policy allows, and its owner told", %{dir: dir} do
    setup_project(dir)
    create(dir, "broken", message: "fail")

    with_project(dir, fn project ->
      tick(project, after_anchor(project, "broken", 5))
      assert ["failed"] = states(project, "broken")
      assert {:ok, %{"state" => "active"}} = Jobs.get(project.conn, "broken")

      tick(project, after_anchor(project, "broken", 10))
      assert ["failed", "failed"] = states(project, "broken")

      assert {:ok, %{"state" => "paused", "state_reason" => reason}} =
               Jobs.get(project.conn, "broken")

      assert reason =~ "2 fires failed in a row"
      assert [notice] = requests(project)
      assert notice =~ "Job broken: paused: 2 fires failed in a row"

      # Paused, it fires no more.
      assert [] = tick(project, after_anchor(project, "broken", 15))
      assert length(fires(project, "broken")) == 2
    end)
  end

  test "a fire that does not start within the tolerance is late, and its owner told", %{dir: dir} do
    setup_project(dir)
    create(dir, "slow")

    with_project(dir, fn project ->
      # Two minutes past the slot, a minute more than the policy allows.
      assert [_started] = tick(project, after_anchor(project, "slow", 5, 120))
      assert ["due", "late", "running", "succeeded"] = history_states(project, "slow")
      assert [notice] = requests(project)
      assert notice =~ "Job slow: a fire is late"
    end)
  end

  defp history_states(project, name) do
    {:ok, history} = Jobs.history(project.conn, name)
    for %{"op" => "fire", "state" => state} <- history, do: state
  end

  test "the slots missed while the server was down are skipped by the policy", %{dir: dir} do
    setup_project(dir)
    create(dir, "away")

    with_project(dir, fn project ->
      assert [] = tick(project, after_anchor(project, "away", 17), true)
      assert ["missed", "missed", "missed"] = states(project, "away")
      assert [%{"reason" => "the server was down"} | _] = fires(project, "away")
    end)
  end

  test "run_once runs the latest missed slot once", %{dir: dir} do
    setup_project(dir, String.replace(@jobs, ~s(missed = "skip"), ~s(missed = "run_once")))
    create(dir, "away")

    with_project(dir, fn project ->
      assert [_one] = tick(project, after_anchor(project, "away", 17), true)
      assert ["missed", "missed", "succeeded"] = states(project, "away")
      # Run on purpose, so it is not late.
      assert [] = requests(project)
    end)
  end

  test "the fires a stopped server left running fail at the start", %{dir: dir} do
    setup_project(dir)
    create(dir, "cut")

    with_project(dir, fn project ->
      now = after_anchor(project, "cut", 5)

      assert [_started] =
               Cycle.run(project, nil, fn project -> elem(Scheduler.plan(project, now), 1) end)

      assert ["running"] = states(project, "cut")

      assert [] = tick(project, now, true)

      assert [%{"state" => "failed", "reason" => "the server stopped while the fire ran"}] =
               fires(project, "cut")
    end)
  end

  test "a job whose end date passed is ended", %{dir: dir} do
    setup_project(dir)
    create(dir, "short", end_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 7 * 60)))

    with_project(dir, fn project ->
      assert [_started] = tick(project, after_anchor(project, "short", 5))
      assert {:ok, %{"state" => "active"}} = Jobs.get(project.conn, "short")

      # The next slot is past the end date.
      assert [] = tick(project, after_anchor(project, "short", 11))

      assert {:ok, %{"state" => "ended", "state_reason" => "the end date passed"}} =
               Jobs.get(project.conn, "short")

      assert ["succeeded"] = states(project, "short")
    end)
  end

  test "no more fires run at once than max_parallel allows", %{dir: dir} do
    setup_project(dir)
    for name <- ~w(one two three), do: create(dir, name)

    with_project(dir, fn project ->
      now = after_anchor(project, "three", 5)

      Cycle.run(project, nil, fn project ->
        assert {:ok, [first, second]} = Scheduler.plan(project, now)
        assert {:ok, []} = Scheduler.plan(project, now)

        # Both are running; the third waits, due.
        assert Enum.sort(Enum.map([first, second], & &1.job["name"])) == ~w(one two)
        assert ["running"] = states(project, "one")
        assert ["due"] = states(project, "three")

        for started <- [first, second], do: :ok = Fire.run(project, started.job, started.fire)
        assert {:ok, [%{job: %{"name" => "three"}}]} = Scheduler.plan(project, now)
      end)
    end)
  end

  test "a preview gives the next fires and no estimate without history", %{dir: dir} do
    setup_project(dir)

    with_project(dir, fn project ->
      {:ok, config} = Fixtures.load_config(dir)

      params = %{
        "schedule" => "every 5m",
        "timezone" => "UTC",
        "target" => %{"agent" => "keeper"}
      }

      assert {:ok, %{"next" => [_, _, _], "estimate_usd" => nil, "basis" => basis}} =
               Preview.build(project.conn, config, params)

      assert basis =~ "so there is no estimate"

      assert {:error, {:jobs, {:unknown_agent, "ghost"}}} =
               Preview.build(project.conn, config, put_in(params, ["target", "agent"], "ghost"))
    end)

    assert {:ok, said} =
             CLI.run(
               ~w(jobs preview --schedule) ++
                 ["every 5m", "--timezone", "UTC", "--agent", "keeper"],
               dir
             )

    assert said =~ "next fires: "
    assert said =~ "no estimate"
  end

  test "a preview estimates from the runs of the agent, then from the fires of jobs", %{dir: dir} do
    setup_project(dir)
    create(dir, "morning")
    assert {:ok, _said} = CLI.run(["send", "--agent", "keeper", "hello"], dir)

    with_project(dir, fn project ->
      {:ok, config} = Fixtures.load_config(dir)

      params = %{
        "schedule" => "every 5m",
        "timezone" => "UTC",
        "target" => %{"agent" => "keeper"}
      }

      assert {:ok, %{"estimate_usd" => usd, "basis" => basis}} =
               Preview.build(project.conn, config, params)

      assert_in_delta usd, 0.002, 1.0e-9
      assert basis =~ "latest runs"

      tick(project, after_anchor(project, "morning", 5))

      assert {:ok, %{"estimate_usd" => usd, "basis" => basis}} =
               Preview.build(project.conn, config, params)

      assert_in_delta usd, 0.002, 1.0e-9
      assert basis =~ "1 latest fires"
    end)
  end
end
