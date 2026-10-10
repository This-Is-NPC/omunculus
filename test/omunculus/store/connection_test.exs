defmodule Omunculus.Store.ConnectionTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Store
  alias Omunculus.Store.{Connection, Events, Query}

  test "appends from many processes, in a transaction or not, apply one after another",
       %{conn: conn} do
    append = fn -> Events.append(conn, %{type: "comment", body: "{}"}) end

    1..20
    |> Enum.map(fn n ->
      Task.async(fn -> if rem(n, 2) == 0, do: Query.transaction(conn, append), else: append.() end)
    end)
    |> Task.await_many()

    assert {:ok, rows} = Query.all(conn, "SELECT sequence FROM events ORDER BY sequence")
    assert Enum.map(rows, & &1.sequence) == Enum.to_list(1..20)
  end

  test "an exception in the owner is raised in the caller and rolls back", %{conn: conn} do
    assert_raise RuntimeError, "boom", fn ->
      Query.transaction(conn, fn ->
        {:ok, _event} = Events.append(conn, %{type: "comment", body: "{}"})
        raise "boom"
      end)
    end

    assert {:ok, []} = Query.all(conn, "SELECT * FROM events")
  end

  test "subscribers hear of appended events once their transaction returns", %{conn: conn} do
    :ok = Store.subscribe(conn)
    owner = conn.owner
    test = self()

    {:ok, _event} =
      Query.transaction(conn, fn ->
        {:ok, event} = Events.append(conn, %{type: "comment", body: "{}"})
        send(test, :written)
        {:ok, event}
      end)

    assert_receive :written
    assert_receive {:store, ^owner, :events}
    refute_received {:store, ^owner, :events}

    {:ok, _event} = Events.append(conn, %{type: "comment", body: "{}"})
    assert_receive {:store, ^owner, :events}
  end

  test "the owner stops when the process that opened it exits" do
    parent = self()

    opener =
      spawn(fn ->
        {:ok, conn} = Store.open(":memory:")
        send(parent, {:conn, conn})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:conn, %Connection{owner: owner}}, 5_000
    monitor = Process.monitor(owner)
    send(opener, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
  end
end
