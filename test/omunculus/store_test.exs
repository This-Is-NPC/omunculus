defmodule Omunculus.StoreTest do
  use ExUnit.Case, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store

  @ctx %{run_id: nil, author: "human", work_id: nil, agent: nil}

  setup do
    path = Path.join(System.tmp_dir!(), "omunculus-#{Omunculus.Id.new()}.sqlite3")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "a comment written through the store survives reopening the file", %{path: path} do
    {:ok, conn} = Store.open(path)
    work_id = Fixtures.insert(conn, :works)
    emit = %{"type" => "comment", "body" => %{"work_id" => work_id, "body" => "first"}}
    call = %{name: "comment", args: %{}, ok: true, output: "first"}

    assert {:ok, [tool_event, event]} = Store.record_tool(conn, nil, call, [emit], @ctx)
    :ok = Store.close(conn)

    {:ok, conn} = Store.open(path)
    assert {:ok, [^tool_event, ^event]} = Store.replay(conn, :project)

    assert {:ok, [%{body: "first", event_id: event_id}]} =
             Store.view(conn, "comments.work", work_id)

    assert event_id == event.id
    :ok = Store.close(conn)
  end
end
