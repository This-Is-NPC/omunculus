defmodule Omunculus.Benchmark.StubTest do
  use ExUnit.Case, async: false

  alias Omunculus.Benchmark.Stub

  test "supports health, configure, request, stats, and stop lifecycle" do
    assert {:ok, stub} = Stub.start(timeout: 10_000)
    on_exit(fn -> Stub.stop(stub) end)
    assert {:ok, health} = Req.get(stub.base_url <> "/health")
    assert health.status == 200
    assert health.body["ok"]

    assert :ok = Stub.configure(stub, delay_ms: 5, payload_bytes: 32)

    assert {:ok, response} =
             Req.post(stub.base_url <> "/v1/chat/completions",
               json: %{model: "benchmark", messages: [%{role: "user", content: "ping"}]}
             )

    assert response.status == 200
    assert {:ok, stats} = Stub.stats(stub)
    assert stats["requests"] == 1
    assert stats["completed"] == 1
    assert stats["failed"] == 0
    assert stats["in_flight"] == 0
    assert stats["active_peak"] == 1
    assert :ok = Stub.stop(stub)
  end

  test "fails a partial in-flight barrier safely" do
    assert {:ok, stub} = Stub.start(timeout: 10_000)
    on_exit(fn -> Stub.stop(stub) end)
    assert :ok = Stub.configure(stub, expected_in_flight: 2, barrier_timeout_ms: 30)

    assert {:ok, response} =
             Req.post(stub.base_url <> "/v1/chat/completions",
               json: %{model: "benchmark", messages: [%{role: "user", content: "ping"}]},
               receive_timeout: 1_000
             )

    assert response.status == 408
    assert {:ok, stats} = Stub.stats(stub)
    assert stats["completed"] == 0
    assert stats["failed"] == 1
    assert stats["barrier_timeouts"] == 1
  end
end
