defmodule Omunculus.CLI.SendTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Omunculus.CLI.{Parser, Spec}
  alias Omunculus.{EventCore, Harness, SessionExecutor}

  test "send exposes the fake provider, session and profile" do
    {:ok, parsed} =
      Parser.parse(
        [
          "send",
          "conte até 3",
          "--provider",
          "fake",
          "--profile",
          "count",
          "--session",
          "/tmp/example.db"
        ],
        %{}
      )

    assert parsed.flags["provider"] == "fake"
    assert parsed.flags["profile"] == "count"
    assert parsed.flags["session"] == "/tmp/example.db"
    refute Map.has_key?(Spec.commands(), "spike")
  end

  test "send help describes durable execution and fake provider" do
    output = capture_io(fn -> assert Omunculus.CLI.dispatch(["send", "--help"], %{}) == 0 end)
    assert output =~ "EVENTS"
    assert output =~ "--provider"
    assert output =~ "--detach"
  end

  for {base, depth} <- [{"simple.toml", 0}, {"medium.toml", 1}, {"complex.toml", 2}] do
    test "send fake runs #{base} and leaves a durable log" do
      tmp = Harness.tmp_fixture(unquote(base))
      db = Path.join(tmp.dir, "send.sqlite3")

      on_exit(fn ->
        pid = :global.whereis_name({SessionExecutor, db})
        if is_pid(pid), do: SessionExecutor.stop(pid)
        File.rm_rf!(tmp.dir)
      end)

      output =
        capture_io(fn ->
          assert Omunculus.CLI.dispatch(
                   [
                     "send",
                     "conte até 4",
                     "--provider",
                     "fake",
                     "--profile",
                     "count",
                     "--config",
                     tmp.path,
                     "--session",
                     db
                   ],
                   %{}
                 ) == 0
        end)

      assert String.trim(output) == "4"
      core = :global.whereis_name({SessionExecutor, db}) |> SessionExecutor.core()
      events = EventCore.stream(core, 0)
      assert Enum.count(events, &(&1.type == "task.completed")) == unquote(depth) + 1

      assert Enum.count(
               events,
               &(&1.type == "tool.call.completed" and &1.payload["tool"] == "counter")
             ) == 4

      assert File.exists?(db)
    end
  end
end
