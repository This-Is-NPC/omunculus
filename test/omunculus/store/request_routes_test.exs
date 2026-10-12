defmodule Omunculus.Store.RequestRoutesTest do
  use Omunculus.StoreCase, async: true
  alias Omunculus.{Fixtures, Id, Participant, Store}
  alias Omunculus.Store.Query

  test "a workless route cannot deliver to a workflow-only agent", %{conn: conn} do
    config =
      Fixtures.config("""
      [agents.stage]
      depth = 0
      workflow_only = true
      text = "stage"
      [policy]
      request_routes = [
        { name = "stage", via = [{ kind = "agent", agent = "stage" }] },
        { name = "next", via = [{ kind = "agent", agent = "stage" }, "origin"] }
      ]
      """)

    conversation = Id.new()

    :ok =
      Query.insert(conn, :conversations, %{
        id: conversation,
        created_issuer: "test",
        created_subject: "owner",
        created_at: "2026-01-01"
      })

    ctx = %{
      run_id: nil,
      work_id: nil,
      author: "human",
      agent: nil,
      issuer: "test",
      subject: "client",
      config: config,
      groups: %{},
      conversation_id: conversation
    }

    request = fn route ->
      body = %{"reason" => "Question", "options" => %{}, "to" => route}

      Store.record_tools(
        conn,
        nil,
        [{%{name: "ask", args: %{}}, [%{"type" => "request", "body" => body}]}],
        ctx
      )
    end

    assert {:error, {:request, :no_route}} = request.("stage")
    assert {:ok, []} = Query.all(conn, "SELECT id FROM requests")
    assert {:ok, [_tool, event]} = request.("next")
    assert {:ok, row} = Store.view(conn, "request", event.request_id)
    assert Jason.decode!(row.arbiter) == Participant.human("test", "owner")
  end
end
