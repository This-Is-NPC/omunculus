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
end

defmodule Omunculus.Execution.ProcessTest do
  use ExUnit.Case, async: false

  alias Omunculus.Execution.{Command, Limiter, Policy, Process}

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
      Process.start(command, policy(), self(), ref, Omunculus.Execution.ProcessTest.FakeBackend)

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
        Omunculus.Execution.ProcessTest.FakeBackend
      )

    assert :ok = Process.write(pid, "toolong")
    assert_receive {:execution, ^ref, {:error, :max_output_bytes}}
  end

  test "limits concurrent executions and rejects a full queue" do
    limits = %{max_concurrent: 1, max_queue: 1, queue_timeout_ms: 100}
    assert :ok = Limiter.acquire(limits)

    waiting = Task.async(fn -> Limiter.acquire(limits) end)
    :timer.sleep(10)
    rejected = Task.async(fn -> Limiter.acquire(limits) end)

    assert {:ok, {:error, :queue_full}} = Task.yield(rejected, 100)
    assert :ok = Limiter.release(limits)
    assert {:ok, :ok} = Task.yield(waiting, 100)
  end

  test "removes a timed-out queue entry before admitting another execution" do
    limits = %{max_concurrent: 1, max_queue: 2, queue_timeout_ms: 20}
    assert :ok = Limiter.acquire(limits)

    timed_out = Task.async(fn -> Limiter.acquire(limits) end)
    assert {:ok, {:error, :queue_timeout}} = Task.yield(timed_out, 100)

    :timer.sleep(20)
    assert :ok = Limiter.release(limits)
    assert :ok = Limiter.acquire(limits)
    assert :ok = Limiter.release(limits)
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
      tools: []
    }
  end
end
