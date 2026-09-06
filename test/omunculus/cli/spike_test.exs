defmodule Omunculus.CLI.SpikeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Omunculus.CLI.Parser

  test "spike parses depth, db, fail-at, delay and json-events" do
    assert {:ok, parsed} =
             Parser.parse(
               [
                 "spike",
                 "conte até 10",
                 "--depth",
                 "2",
                 "--db",
                 "/tmp/x.db",
                 "--fail-at",
                 "3",
                 "--delay",
                 "10ms",
                 "--json-events"
               ],
               %{}
             )

    assert parsed.command == :spike
    assert parsed.args.instruction == "conte até 10"
    assert parsed.flags["depth"] == "2"
    assert parsed.flags["db"] == "/tmp/x.db"
    assert parsed.flags["fail_at"] == "3"
    assert parsed.flags["delay"] == "10ms"
    assert parsed.flags["json_events"] == true
  end

  test "spike --depth defaults to 1" do
    assert {:ok, parsed} = Parser.parse(["spike", "conte até 3"], %{})
    assert parsed.flags["depth"] == "1"
  end

  test "spike help mentions the log and the scenarios" do
    {code, out} = with_io(fn -> Omunculus.CLI.dispatch(["spike", "--help"], %{}) end)
    assert code == 0
    assert out =~ "EVENTS"
    assert out =~ "--fail-at"
  end

  test "spike rejects a negative depth with a usage error" do
    {code, err} =
      with_io(:stderr, fn ->
        Omunculus.CLI.dispatch(["spike", "conte até 3", "--depth", "-1"], %{})
      end)

    assert code == 2
    assert err =~ "invalid value"
  end

  test "spike runs scenario 4 against a file-backed core and prints durable state" do
    db =
      Path.join(
        System.tmp_dir!(),
        "omunculus-spike-test-#{System.unique_integer([:positive])}.sqlite3"
      )

    {out, err} =
      with_io(fn ->
        err =
          capture_io(:stderr, fn ->
            assert Omunculus.CLI.dispatch(
                     ["spike", "conte até 4", "--depth", "2", "--db", db],
                     %{}
                   ) == 0
          end)

        send(self(), {:err, err})
      end)
      |> then(fn {_code, out} ->
        receive do
          {:err, err} -> {out, err}
        end
      end)

    assert String.trim(out) == "4"
    assert err =~ "task.requested"
    assert err =~ "to_depth=1"
    assert err =~ "to_depth=2"
    assert err =~ "counter 3->4"
    assert err =~ "replay: projections rebuilt from EVENTS identically"
    assert err =~ "depth=2 attempt=1 worker completed"
    assert File.exists?(db)

    # The log is durable: reopen the file and read it back in sequence order.
    {:ok, core} = Omunculus.EventCore.start_link(path: db)
    events = Omunculus.EventCore.stream(core, 0)
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))
    assert Enum.count(events, &(&1.type == "task.completed")) == 3
    GenServer.stop(core)
    File.rm(db)
  end

  test "spike --fail-at kills the worker, records run.failed and resumes as attempt 2" do
    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            assert Omunculus.CLI.dispatch(
                     ["spike", "conte até 6", "--fail-at", "2", "--delay", "30ms"],
                     %{}
                   ) == 0
          end)

        assert String.trim(out) == "6"
      end)

    assert err =~ "run.failed"
    assert err =~ "task.resumed"
    assert err =~ "depth=1 attempt=1 worker failed"
    assert err =~ "depth=1 attempt=2 worker completed"
    assert err =~ "counter 5->6"
    assert err =~ "replay: projections rebuilt from EVENTS identically"
  end
end
