defmodule Omunculus.Store.ConnectionTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Store
  alias Omunculus.Store.{Connection, Events, Query}

  test "transactions from many processes apply one after another", %{conn: conn} do
    1..20
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Query.transaction(conn, fn -> Events.append(conn, %{type: "comment", body: "{}"}) end)
      end)
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

  test "the owner stops when the process that opened it exits" do
    parent = self()

    opener =
      spawn(fn ->
        {:ok, conn} = Store.open(":memory:")
        send(parent, {:conn, conn})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:conn, %Connection{owner: owner}}
    monitor = Process.monitor(owner)
    send(opener, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end
end
