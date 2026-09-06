defmodule Omunculus.HarnessTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config
  alias Omunculus.Event.Envelope
  alias Omunculus.EventCore
  alias Omunculus.Harness

  test "await_log finds an already-appended task.requested" do
    {:ok, core} = EventCore.start_link(path: ":memory:")

    cmd = Envelope.command("task.requested", payload: %{instruction: "harness"})
    {:ok, stored} = EventCore.append(core, cmd)

    assert stored.event_id ==
             Harness.await_log(core, &(&1.type == "task.requested")).event_id
  end

  test "await_log waits for an envelope appended after the call starts" do
    {:ok, core} = EventCore.start_link(path: ":memory:")

    waiter =
      Task.async(fn ->
        Harness.await_log(core, &(&1.type == "task.completed"))
      end)

    assert Process.alive?(waiter.pid)
    Process.sleep(50)

    requested = Envelope.command("task.requested", payload: %{instruction: "wait"})
    {:ok, requested} = EventCore.append(core, requested)

    completed =
      Envelope.event("task.completed",
        correlation_id: requested.correlation_id,
        causation_id: requested.event_id,
        payload: %{result: "done", depth: 0}
      )

    {:ok, stored} = EventCore.append(core, completed)

    assert stored.event_id == Task.await(waiter, 5_000).event_id
  end

  test "tmp_fixture copies simple.toml to a writable tmpdir" do
    fixture = Harness.tmp_fixture("simple.toml")
    on_exit(fn -> File.rm_rf!(fixture.dir) end)

    assert Map.has_key?(fixture.config.presets, "count")
    assert Map.has_key?(fixture.config.presets, "coding")

    File.write!(
      fixture.path,
      File.read!(fixture.path) <> "\n[profiles.custom]\nmode = \"allow\"\n"
    )

    {:ok, reloaded} = Config.load(cwd: fixture.dir, config_file: fixture.path, env: %{})
    assert Map.has_key?(reloaded.presets, "custom")
    refute Map.has_key?(fixture.config.presets, "custom")
  end

  test "tmp_fixture with overlay appends lane interceptors" do
    fixture = Harness.tmp_fixture("medium.toml", "lane.toml")
    on_exit(fn -> File.rm_rf!(fixture.dir) end)

    assert fixture.config.interceptors != []

    names = Enum.map(fixture.config.interceptors, & &1.name)
    assert "audit" in names
    assert "depth-gate" in names
  end
end
