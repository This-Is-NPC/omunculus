defmodule Omunculus.Tools.JobsToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Tools.{Jobs, ProposeJob}

  defp emitted(%{"ok" => true, "emit" => [%{"type" => "job", "body" => body}]}), do: body

  test "create emits a job action with the fields, the channel and the approving request" do
    args = %{
      "action" => "create",
      "name" => "n",
      "agent" => "front",
      "message" => "m",
      "schedule" => "every 2h",
      "timezone" => "UTC",
      "channel" => "api",
      "request_id" => "r1",
      "state" => "proposed",
      "bogus" => "x"
    }

    assert emitted(Jobs.run(%{args: args, view: %{}})) == %{
             "op" => "create",
             "name" => "n",
             "agent" => "front",
             "message" => "m",
             "schedule" => "every 2h",
             "timezone" => "UTC",
             "channel" => "api",
             "request_id" => "r1",
             "state" => "proposed"
           }
  end

  test "pause, resume, archive, run, read and duplicate name their job" do
    run = fn args -> emitted(Jobs.run(%{args: args, view: %{}})) end

    assert %{"op" => "transition", "to" => "paused", "job" => "n", "reason" => "x"} =
             run.(%{"action" => "pause", "name" => "n", "reason" => "x"})

    assert %{"to" => "active"} = run.(%{"action" => "resume", "name" => "n"})
    assert %{"to" => "archived"} = run.(%{"action" => "archive", "name" => "n"})
    assert %{"op" => "run", "job" => "n"} = run.(%{"action" => "run", "name" => "n"})
    assert %{"op" => "read", "job" => "n"} = run.(%{"action" => "read", "name" => "n"})

    assert %{"op" => "duplicate", "job" => "n", "name" => "m"} =
             run.(%{"action" => "duplicate", "name" => "n", "as" => "m"})
  end

  test "a call missing what it needs, or naming no action, fails" do
    assert %{"ok" => false, "output" => "name required"} =
             Jobs.run(%{args: %{"action" => "pause"}, view: %{}})

    assert %{"ok" => false, "output" => "as required"} =
             Jobs.run(%{args: %{"action" => "duplicate", "name" => "n"}, view: %{}})

    assert %{"ok" => false, "output" => "action is one of: " <> _} =
             Jobs.run(%{args: %{"action" => "burn"}, view: %{}})

    assert %{"ok" => false, "output" => "no job n"} =
             Jobs.run(%{args: %{"action" => "show", "name" => "n"}, view: %{"jobs" => []}})
  end

  test "propose_job without a [jobs] table fails, and with one asks" do
    dir = Fixtures.tmp_dir()
    Fixtures.write_config(dir, "[agents.front]\ndepth = 0\ntext = \"f\"\n")

    args = %{
      "name" => "n",
      "agent" => "front",
      "message" => "m",
      "schedule" => "daily at 07:00",
      "timezone" => "UTC",
      "reason" => "r"
    }

    assert %{"ok" => false, "output" => "omunculus.toml has no [jobs] table" <> _} =
             ProposeJob.run(%{args: args, config_path: Fixtures.config_path(dir)})

    File.write!(
      Fixtures.config_path(dir),
      File.read!(Fixtures.config_path(dir)) <>
        """

        [jobs]
        max_parallel = 1
        min_interval_minutes = 5
        max_jobs = 1
        missed = "skip"
        lateness_seconds = 60
        failures_before_pause = 3
        agent_may_create = false
        """
    )

    path = Fixtures.config_path(dir)
    out = ProposeJob.run(%{args: Map.put(args, "delivery", "owner_inbox"), config_path: path})

    assert %{
             "ok" => true,
             "chain" => [%{"name" => "end"}],
             "emit" => [%{"type" => "request", "body" => body}]
           } = out

    assert body["reason"] =~ "delivers: each reply to the owner's inbox"

    assert %{
             "approve" => [
               %{"name" => "jobs", "args" => %{"delivery" => "owner_inbox", "action" => "create"}}
             ]
           } = body["options"]

    # A run that a job's fire opened proposes nothing.
    assert %{
             "ok" => false,
             "output" => "a run that a job's fire opened may not create or change jobs"
           } =
             ProposeJob.run(%{
               args: args,
               config_path: path,
               view: %{"fire" => %{"fired" => true}}
             })

    # The project holds as many jobs as it may.
    assert %{"ok" => false, "output" => "the project holds 1 jobs" <> _} =
             ProposeJob.run(%{
               args: %{args | "name" => "other"},
               config_path: path,
               view: %{"jobs" => [%{"name" => "n"}]}
             })
  end
end
