defmodule Omunculus.JobsFlowTest do
  use ExUnit.Case, async: true

  alias Omunculus.{CLI, Fixtures, Jobs, Project}
  alias Omunculus.Store.Query

  import Omunculus.Fixtures, only: [open_project: 1, write_config: 2]

  @jobs """
  [jobs]
  max_parallel = 2
  min_interval_minutes = 5
  max_jobs = 5
  missed = "skip"
  lateness_seconds = 60
  failures_before_pause = 3
  agent_may_create = false
  """

  @weekly %{
    "name" => "weekly",
    "agent" => "keeper",
    "message" => "Review the week.",
    "schedule" => "0 9 * * 1",
    "timezone" => "Europe/Paris",
    "reason" => "the week deserves a look"
  }

  defp setup_project(dir, jobs \\ @jobs) do
    write_config(dir, """
    [agents.keeper]
    depth = 0
    text = "I keep the project."
    tools = ["propose_job", "end"]

    #{jobs}
    """)

    # A message names the proposal to make; an answer ends the run.
    Fixtures.use_model(dir, fn assembled, _tools, call ->
      if assembled =~ "## Request\n" do
        call.("end", %{})
      else
        [_, message] = List.last(Regex.scan(~r/## Message\n(.*)/, assembled))
        call.("propose_job", Map.merge(@weekly, Jason.decode!(message)))
      end
    end)
  end

  defp propose(dir, changes), do: CLI.run(["send", Jason.encode!(changes)], dir)

  defp read(dir, fun) do
    project = open_project(dir)

    try do
      fun.(project.conn)
    after
      Project.close(project)
    end
  end

  setup do
    dir = Fixtures.tmp_dir()
    %{dir: dir}
  end

  test "a proposal is a request, and approving it creates the job with its origin", %{dir: dir} do
    setup_project(dir)
    assert {:ok, _said} = propose(dir, %{})

    request =
      read(dir, fn conn ->
        assert {:ok, []} = Jobs.list(conn)
        assert {:ok, [request]} = Query.all(conn, "SELECT * FROM requests")

        assert {:ok, %{body: body}} =
                 Query.one(conn, "SELECT body FROM events WHERE id = ?", [request.event_id])

        reason = Jason.decode!(body)["reason"]

        assert request.status == "pending"
        assert reason =~ "the week deserves a look"
        assert reason =~ "job weekly as it would run:"
        assert reason =~ "runs: keeper is sent \"Review the week.\""
        assert reason =~ "when: 0 9 * * 1 (Europe/Paris)"
        assert reason =~ "next fires: "
        assert reason =~ "runs as: whoever approves it"

        assert %{"approve" => [%{"name" => "jobs"}], "edit" => [], "deny" => []} =
                 Jason.decode!(request.options)

        request
      end)

    assert {:ok, _said} =
             CLI.run(["reply", "--request_id", request.id, "--option", "approve", "go"], dir)

    read(dir, fn conn ->
      assert {:ok, %{"name" => "weekly", "state" => "active", "version" => 1} = job} =
               Jobs.get(conn, "weekly")

      assert job["origin"]["channel"] == "proposal"
      assert job["origin"]["request_id"] == request.id
      assert %{"kind" => "human", "issuer" => "local"} = job["owner"]
      assert job["next_fire"]
    end)
  end

  test "a proposal that is not valid is refused before the person is asked", %{dir: dir} do
    setup_project(dir)

    for bad <- [%{"agent" => "ghost"}, %{"schedule" => "every 1m"}, %{"timezone" => "Mars/Base"}] do
      assert {:ok, _said} = propose(dir, bad)
    end

    read(dir, fn conn -> assert {:ok, []} = Query.all(conn, "SELECT * FROM requests") end)
  end

  test "a proposal the person denied is not asked again", %{dir: dir} do
    setup_project(dir)
    assert {:ok, _said} = propose(dir, %{})
    request = read(dir, fn conn -> elem(Query.one(conn, "SELECT * FROM requests"), 1) end)

    assert {:ok, _said} =
             CLI.run(["reply", "--request_id", request.id, "--option", "deny", "no"], dir)

    assert {:ok, _said} = propose(dir, %{})
    read(dir, fn conn -> assert {:ok, [_only]} = Query.all(conn, "SELECT id FROM requests") end)

    assert {:ok, _said} = propose(dir, %{"message" => "Review it differently."})

    read(dir, fn conn ->
      assert {:ok, [_one, _two]} = Query.all(conn, "SELECT id FROM requests")
    end)
  end

  test "where the policy lets agents create jobs, the job is created at once", %{dir: dir} do
    setup_project(
      dir,
      String.replace(@jobs, "agent_may_create = false", "agent_may_create = true")
    )

    assert {:ok, _said} = propose(dir, %{})

    read(dir, fn conn ->
      assert {:ok, []} = Query.all(conn, "SELECT * FROM requests")

      assert {:ok,
              %{
                "owner" => %{"kind" => "agent", "agent" => "keeper"},
                "origin" => %{"channel" => "tool"}
              }} =
               Jobs.get(conn, "weekly")
    end)
  end

  test "without a [jobs] table a proposal is refused", %{dir: dir} do
    setup_project(dir, "")
    assert {:ok, _said} = propose(dir, %{})
    read(dir, fn conn -> assert {:ok, []} = Query.all(conn, "SELECT * FROM requests") end)
  end

  test "the command line creates, reads, changes and archives jobs", %{dir: dir} do
    setup_project(dir)
    run = fn args -> CLI.run(args, dir) end

    assert {:ok, "No jobs."} = run.(["jobs", "list"])

    assert {:ok, "created nightly"} =
             run.([
               "jobs",
               "create",
               "--name",
               "nightly",
               "--agent",
               "keeper",
               "--message",
               "Tidy up.",
               "--schedule",
               "daily at 02:30",
               "--timezone",
               "UTC"
             ])

    assert {:error, {:jobs, {:name_taken, "nightly"}}} =
             run.([
               "jobs",
               "create",
               "--name",
               "nightly",
               "--agent",
               "keeper",
               "--message",
               "x",
               "--schedule",
               "every 1h",
               "--timezone",
               "UTC"
             ])

    assert {:ok, list} = run.(["jobs", "list"])
    assert list =~ "- nightly [active] daily at 02:30 (UTC); next "

    assert {:ok, shown} = run.(["jobs", "show", "--name", "nightly"])
    assert shown =~ "nightly [active], version 1"
    assert shown =~ "runs: keeper is sent \"Tidy up.\""
    assert shown =~ "next fires: "

    assert {:ok, "changed nightly"} =
             run.(["jobs", "edit", "--name", "nightly", "--schedule", "daily at 03:00"])

    assert {:ok, "paused nightly"} =
             run.(["jobs", "pause", "--name", "nightly", "--reason", "away"])

    assert {:ok, "queued a run of nightly"} = run.(["jobs", "run", "--name", "nightly"])

    assert {:ok, "copied nightly to again"} =
             run.(["jobs", "duplicate", "--name", "nightly", "--as", "again"])

    assert {:ok, "resumed nightly"} = run.(["jobs", "resume", "--name", "nightly"])

    assert {:ok, history} = run.(["jobs", "history", "--name", "nightly"])
    assert history =~ "create version 1 by local:"
    assert history =~ "change version 2"
    assert history =~ "transition active -> paused: away"
    assert history =~ "fire due fire"

    assert {:ok, "archived nightly"} = run.(["jobs", "archive", "--name", "nightly"])

    assert {:error, {:tool_failed, "no job nightly"}} =
             run.(["jobs", "show", "--name", "nightly"])

    assert {:ok, "- again [proposed]" <> _} = run.(["jobs", "list"])
  end
end
