defmodule Omunculus.Execution.ProcessTest.FakeBackend do
  @behaviour Omunculus.Execution.Backend

  @impl true
  def start(_command, _policy, owner, ref), do: {:ok, %{owner: owner, ref: ref}}

  @impl true
  def write(handle, data) do
    send(handle.owner, {:execution, handle.ref, {:stdout, IO.iodata_to_binary(data)}})
    :ok
  end

  @impl true
  def close_input(handle) do
    send(handle.owner, {:execution, handle.ref, {:stderr, "diagnostic"}})
    send(handle.owner, {:execution, handle.ref, {:exit, 0}})
    :ok
  end

  @impl true
  def stop(handle, reason) do
    send(handle.owner, {:execution, handle.ref, {:exit, 1}})
    send(self(), {:fake_stopped, reason})
    :ok
  end

  @impl true
  def cleanup(_handle), do: :ok

  @impl true
  def exit_status(_handle, fallback), do: fallback
end

defmodule Omunculus.Execution.ProcessTest do
  use ExUnit.Case, async: false

  alias Omunculus.Execution.{Command, Limiter, Policy, Process}
  alias Omunculus.ExecutionPolicyFixtures

  @limits %{
    timeout_ms: 1_000,
    max_output_bytes: 32,
    max_concurrent: 1,
    max_queue: 1,
    queue_timeout_ms: 100
  }

  test "forwards normalized streams from a backend without exposing its handle" do
    ref = make_ref()
    {:ok, command} = Command.new("/usr/bin/true")

    {:ok, pid} =
      Process.start(
        command,
        policy(),
        self(),
        ref,
        Omunculus.Execution.ProcessTest.FakeBackend,
        make_ref(),
        :tool
      )

    assert :ok = Process.write(pid, "output")
    assert :ok = Process.close_input(pid)
    assert_receive {:execution, ^ref, {:stdout, "output"}}
    assert_receive {:execution, ^ref, {:stderr, "diagnostic"}}
    assert_receive {:execution, ^ref, {:exit, 0}}
  end

  test "stops a backend before forwarding output beyond the configured limit" do
    ref = make_ref()
    {:ok, command} = Command.new("/usr/bin/true")

    {:ok, pid} =
      Process.start(
        command,
        policy(max_output_bytes: 3),
        self(),
        ref,
        Omunculus.Execution.ProcessTest.FakeBackend,
        make_ref(),
        :tool
      )

    assert :ok = Process.write(pid, "toolong")
    assert_receive {:execution, ^ref, {:error, :max_output_bytes}}
  end

  test "limits concurrent executions and rejects a full queue" do
    limits = %{max_concurrent: 1, max_queue: 1, queue_timeout_ms: 100}
    assert {:ok, first} = Limiter.acquire(limits, self(), :tool)

    waiting = Task.async(fn -> Limiter.acquire(limits, self(), :tool) end)
    :timer.sleep(10)
    rejected = Task.async(fn -> Limiter.acquire(limits, self(), :tool) end)

    assert {:ok, {:error, :queue_full}} = Task.yield(rejected, 100)
    assert :ok = Limiter.release(limits, first, :tool)
    assert {:ok, {:ok, lease}} = Task.yield(waiting, 100)
    assert :ok = Limiter.release(limits, lease, :tool)
  end

  test "removes a timed-out queue entry before admitting another execution" do
    limits = %{max_concurrent: 1, max_queue: 2, queue_timeout_ms: 20}
    assert {:ok, first} = Limiter.acquire(limits, self(), :tool)

    timed_out = Task.async(fn -> Limiter.acquire(limits, self(), :tool) end)
    assert {:ok, {:error, :queue_timeout}} = Task.yield(timed_out, 100)

    :timer.sleep(20)
    assert :ok = Limiter.release(limits, first, :tool)
    assert {:ok, second} = Limiter.acquire(limits, self(), :tool)
    assert :ok = Limiter.release(limits, second, :tool)
  end

  test "reserves a coordinator lane for a nested tool call" do
    limits = %{max_concurrent: 1, max_queue: 1, queue_timeout_ms: 100}
    assert {:ok, tool} = Limiter.acquire(limits, self(), :tool)
    assert {:ok, coordinator} = Limiter.acquire(limits, self(), :coordinator)

    waiting = Task.async(fn -> Limiter.acquire(limits, self(), :coordinator) end)
    :timer.sleep(10)
    assert :ok = Limiter.release(limits, coordinator, :coordinator)
    assert {:ok, {:ok, next}} = Task.yield(waiting, 100)

    assert :ok = Limiter.release(limits, next, :coordinator)
    assert :ok = Limiter.release(limits, tool, :tool)
  end

  defp policy(overrides \\ []) do
    limits = Map.merge(@limits, Map.new(overrides))

    %Policy{
      id: "test-policy",
      workspace: %{name: nil, root: System.tmp_dir!()},
      read_only: [],
      read_write: [],
      hidden: [],
      runtimes: ["/usr"],
      backend: "bubblewrap",
      environment: %{},
      network: "host",
      limits: limits,
      tools: [],
      sandbox: ExecutionPolicyFixtures.sandbox()
    }
  end
end
