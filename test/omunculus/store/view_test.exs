defmodule Omunculus.Store.ViewTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store.View

  describe "comments.work" do
    test "returns only comments of that work, ordered by created_at", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      other_work_id = Fixtures.insert(conn, :works)

      first_id =
        Fixtures.insert(conn, :comments, %{work_id: work_id, created_at: "2026-01-01T00:00:00Z"})

      second_id =
        Fixtures.insert(conn, :comments, %{work_id: work_id, created_at: "2026-01-02T00:00:00Z"})

      Fixtures.insert(conn, :comments, %{work_id: other_work_id})

      assert {:ok, [first, second]} = View.view(conn, "comments.work", work_id)
      assert [first.id, second.id] == [first_id, second_id]
    end

    test "returns an empty list for a work with no comments", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, []} = View.view(conn, "comments.work", work_id)
    end
  end

  describe "comments.request" do
    test "returns only comments of that request", %{conn: conn} do
      request_id = Fixtures.insert(conn, :requests)
      other_request_id = Fixtures.insert(conn, :requests)

      comment_id = Fixtures.insert(conn, :comments, %{request_id: request_id})
      Fixtures.insert(conn, :comments, %{request_id: other_request_id})

      assert {:ok, [comment]} = View.view(conn, "comments.request", request_id)
      assert comment.id == comment_id
    end

    test "returns an empty list for a request with no comments", %{conn: conn} do
      request_id = Fixtures.insert(conn, :requests)

      assert {:ok, []} = View.view(conn, "comments.request", request_id)
    end
  end

  describe "comments.inbox" do
    test "returns only comments of the requested inbox, oldest first", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      other_work_id = Fixtures.insert(conn, :works)

      first_inbox_id = Fixtures.insert(conn, :inbox, %{work_id: work_id})
      second_inbox_id = Fixtures.insert(conn, :inbox, %{work_id: work_id})
      other_inbox_id = Fixtures.insert(conn, :inbox, %{work_id: other_work_id})

      first_id =
        Fixtures.insert(conn, :comments, %{
          inbox_id: first_inbox_id,
          created_at: "2026-01-01T00:00:00Z"
        })

      second_id =
        Fixtures.insert(conn, :comments, %{
          inbox_id: first_inbox_id,
          created_at: "2026-01-02T00:00:00Z"
        })

      Fixtures.insert(conn, :comments, %{inbox_id: other_inbox_id})
      Fixtures.insert(conn, :comments, %{inbox_id: second_inbox_id})

      assert {:ok, [first, second]} = View.view(conn, "comments.inbox", first_inbox_id)
      assert [first.id, second.id] == [first_id, second_id]
    end

    test "returns an empty list for a work with no inbox comments", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, []} = View.view(conn, "comments.inbox", work_id)
    end
  end

  describe "inbox.work" do
    test "lists unread entries of that work only, each with its earliest comment body", %{
      conn: conn
    } do
      work_id = Fixtures.insert(conn, :works)
      other_work_id = Fixtures.insert(conn, :works)

      first_id =
        Fixtures.insert(conn, :inbox, %{
          agent: "concierge",
          work_id: work_id,
          created_at: "2026-01-01T00:00:00Z"
        })

      read_id =
        Fixtures.insert(conn, :inbox, %{
          work_id: work_id,
          created_at: "2026-01-02T00:00:00Z",
          read_at: "2026-01-02T01:00:00Z"
        })

      Fixtures.insert(conn, :inbox, %{work_id: other_work_id})

      Fixtures.insert(conn, :comments, %{inbox_id: first_id, body: "preciso disso"})
      Fixtures.insert(conn, :comments, %{inbox_id: read_id, body: "ignored"})

      assert {:ok, [entry]} = View.view(conn, "inbox.work", work_id)
      assert entry.id == first_id
      assert entry.body == "preciso disso"
    end

    test "returns an empty list for a work with no notifications", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)

      assert {:ok, []} = View.view(conn, "inbox.work", work_id)
    end
  end

  describe "work" do
    test "returns the work row", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works, %{title: "Ship the store"})

      assert {:ok, work} = View.view(conn, "work", work_id)
      assert work.id == work_id
      assert work.title == "Ship the store"
    end

    test "returns nil for an unknown id", %{conn: conn} do
      assert {:ok, nil} = View.view(conn, "work", "missing")
    end
  end

  test "counter derives its value from committed tool calls", %{conn: conn} do
    context = %{run_id: nil, work_id: nil, author: "human", agent: nil, config: nil, groups: %{}}

    assert {:ok, _events} =
             Omunculus.Store.record_tool(
               conn,
               nil,
               %{name: "counter", args: %{}, ok: true, output: "1"},
               [],
               context
             )

    assert {:ok, _events} =
             Omunculus.Store.record_tool(
               conn,
               nil,
               %{name: "counter_decrement", args: %{}, ok: true, output: "0"},
               [],
               context
             )

    assert {:ok, 0} = View.view(conn, "counter", nil)
  end

  describe "work_depth" do
    test "is 0 for a root work", %{conn: conn} do
      work_id = Fixtures.insert(conn, :works)
      {:ok, work} = View.view(conn, "work", work_id)

      assert View.work_depth(conn, work) == 0
    end

    test "is 1 for a child of a root work", %{conn: conn} do
      parent_id = Fixtures.insert(conn, :works)
      child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id})
      {:ok, child} = View.view(conn, "work", child_id)

      assert View.work_depth(conn, child) == 1
    end

    test "is 2 for a grandchild", %{conn: conn} do
      grandparent_id = Fixtures.insert(conn, :works)
      parent_id = Fixtures.insert(conn, :works, %{parent_id: grandparent_id})
      child_id = Fixtures.insert(conn, :works, %{parent_id: parent_id})
      {:ok, child} = View.view(conn, "work", child_id)

      assert View.work_depth(conn, child) == 2
    end
  end

  describe "run" do
    test "returns the run row", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)

      assert {:ok, run} = View.view(conn, "run", run_id)
      assert run.id == run_id
    end

    test "returns nil for an unknown id", %{conn: conn} do
      assert {:ok, nil} = View.view(conn, "run", "missing")
    end
  end

  describe "prompt" do
    test "returns the prompt row", %{conn: conn} do
      prompt_id = Fixtures.insert(conn, :prompts, %{body: "conte até 5"})

      assert {:ok, prompt} = View.view(conn, "prompt", prompt_id)
      assert prompt.id == prompt_id
      assert prompt.body == "conte até 5"
    end

    test "returns nil for an unknown id", %{conn: conn} do
      assert {:ok, nil} = View.view(conn, "prompt", "missing")
    end
  end

  describe "inbox" do
    test "lists unread entries in order, each with its earliest comment body", %{conn: conn} do
      first_id =
        Fixtures.insert(conn, :inbox, %{agent: "concierge", created_at: "2026-01-01T00:00:00Z"})

      second_id =
        Fixtures.insert(conn, :inbox, %{agent: "worker", created_at: "2026-01-02T00:00:00Z"})

      read_id =
        Fixtures.insert(conn, :inbox, %{
          created_at: "2026-01-03T00:00:00Z",
          read_at: "2026-01-03T01:00:00Z"
        })

      Fixtures.insert(conn, :comments, %{
        inbox_id: first_id,
        body: "later",
        created_at: "2026-01-01T01:00:00Z"
      })

      Fixtures.insert(conn, :comments, %{
        inbox_id: first_id,
        body: "earlier",
        created_at: "2026-01-01T00:30:00Z"
      })

      Fixtures.insert(conn, :comments, %{inbox_id: read_id, body: "ignored"})

      assert {:ok, [first, second]} = View.view(conn, "inbox", nil)

      assert first.id == first_id
      assert first.agent == "concierge"
      assert first.body == "earlier"

      assert second.id == second_id
      assert second.agent == "worker"
      assert second.body == nil

      refute Enum.any?([first, second], &(&1.id == read_id))
    end
  end

  test "unknown view name is rejected", %{conn: conn} do
    assert {:error, {:unknown_view, "nope"}} = View.view(conn, "nope", "id")
  end

  describe "replay" do
    test "orders events by sequence, not by at", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)

      third_id =
        Fixtures.insert(conn, :events, %{
          run_id: run_id,
          sequence: 3,
          at: "2026-01-01T00:00:00Z"
        })

      second_id =
        Fixtures.insert(conn, :events, %{
          run_id: run_id,
          sequence: 2,
          at: "2026-01-02T00:00:00Z"
        })

      first_id =
        Fixtures.insert(conn, :events, %{
          run_id: run_id,
          sequence: 1,
          at: "2026-01-03T00:00:00Z"
        })

      assert {:ok, events} = View.replay(conn, {:run, run_id})
      assert Enum.map(events, & &1.id) == [first_id, second_id, third_id]
    end

    test "{:run, id} filters to that run's events", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      other_run_id = Fixtures.insert(conn, :runs)

      event_id = Fixtures.insert(conn, :events, %{run_id: run_id, sequence: 1})
      Fixtures.insert(conn, :events, %{run_id: other_run_id, sequence: 2})

      assert {:ok, [event]} = View.replay(conn, {:run, run_id})
      assert event.id == event_id
    end

    test ":project returns every event across runs, ordered by sequence", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      other_run_id = Fixtures.insert(conn, :runs)

      second_id = Fixtures.insert(conn, :events, %{run_id: run_id, sequence: 2})
      first_id = Fixtures.insert(conn, :events, %{run_id: other_run_id, sequence: 1})

      assert {:ok, events} = View.replay(conn, :project)
      assert Enum.map(events, & &1.id) == [first_id, second_id]
    end

    test "events.run view equals replay({:run, id})", %{conn: conn} do
      run_id = Fixtures.insert(conn, :runs)
      other_run_id = Fixtures.insert(conn, :runs)

      Fixtures.insert(conn, :events, %{run_id: run_id, sequence: 1})
      Fixtures.insert(conn, :events, %{run_id: other_run_id, sequence: 2})

      assert View.view(conn, "events.run", run_id) == View.replay(conn, {:run, run_id})
    end
  end
end
