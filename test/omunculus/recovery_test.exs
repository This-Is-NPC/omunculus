defmodule Omunculus.RecoveryTest do
  use ExUnit.Case, async: true
  alias Omunculus.EventCore
  alias Omunculus.Event.Envelope
  alias Omunculus.Runtime.Recovery

  test "concurrent clients reserve atomically; replay and restart cannot renew the stage" do
    path = Path.join(System.tmp_dir!(), "recovery-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    first = start_supervised!({EventCore, path: path}, id: :first)
    second = start_supervised!({EventCore, path: path}, id: :second)
    ref = %{"work_item_id" => "budget-owner", "stage" => "implement", "max_retries" => 2}
    causes = for n <- 1..12, do: Envelope.event("run.completed", run_id: "run-#{n}")

    results =
      causes
      |> Task.async_stream(
        fn cause ->
          core = if rem(:erlang.phash2(cause.event_id), 2) == 0, do: first, else: second
          {cause, Recovery.reserve(core, ref, cause, "retry")}
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    accepted = Enum.filter(results, fn {_, result} -> match?({:ok, _}, result) end)
    assert length(accepted) == 2

    assert Enum.count(results, fn {_, result} -> result == {:error, :max_retries_exhausted} end) ==
             10

    assert Recovery.used(first, ref) == 2
    [{cause, {:ok, stored}} | _] = accepted
    assert {:ok, ^stored} = Recovery.reserve(second, ref, cause, "retry")
    stop_supervised!(:first)
    stop_supervised!(:second)
    restarted = start_supervised!({EventCore, path: path}, id: :restarted)
    assert Recovery.used(restarted, ref) == 2
    assert {:ok, ^stored} = Recovery.reserve(restarted, ref, cause, "retry")

    assert {:error, :max_retries_exhausted} =
             Recovery.reserve(restarted, ref, Envelope.event("run.completed"), "retry")

    next_stage = %{ref | "stage" => "review"}

    assert {:ok, _} =
             Recovery.reserve(restarted, next_stage, Envelope.event("run.completed"), "retry")

    assert Recovery.used(restarted, next_stage) == 1
    assert Recovery.used(restarted, ref) == 2
  end
end
