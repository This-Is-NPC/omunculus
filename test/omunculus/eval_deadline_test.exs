Code.require_file("../../eval/lib/deadline.ex", __DIR__)

defmodule Omunculus.EvalDeadlineTest do
  use ExUnit.Case, async: true

  alias EquivalentExchange.Deadline

  test "an unlimited conversation stays alive until it returns" do
    parent = self()

    task =
      Task.async(fn ->
        Deadline.run(Deadline.parse("infinity"), fn ->
          send(parent, {:waiting, self()})

          receive do
            :finish -> {:ok, %{answers: ["finished"]}}
          end
        end)
      end)

    assert_receive {:waiting, worker}
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert Task.yield(task, 10) == nil
    assert Process.alive?(worker)
    send(worker, :finish)
    assert Task.await(task) == {{:ok, %{answers: ["finished"]}}, %{answers: ["finished"]}}
  end

  test "a bounded conversation stops its worker when time expires" do
    parent = self()

    task =
      Task.async(fn ->
        Deadline.run(Deadline.parse("1"), fn ->
          send(parent, {:waiting, self()})

          receive do
            :finish -> {:ok, %{}}
          end
        end)
      end)

    assert_receive {:waiting, worker}
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    monitor = Process.monitor(worker)
    assert Task.await(task) == {{:error, :timeout}, nil}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "unlimited conversations preserve errors and reject invalid limits" do
    assert Deadline.run(:infinity, fn -> {:error, :refused} end) == {{:error, :refused}, nil}

    for value <- ["0", "-1", "forever", "1s"] do
      assert_raise ArgumentError, fn -> Deadline.parse(value) end
    end
  end
end
