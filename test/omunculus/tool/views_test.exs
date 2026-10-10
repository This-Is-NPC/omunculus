defmodule Omunculus.Tool.ViewsTest do
  use Omunculus.StoreCase, async: true

  alias Omunculus.Fixtures
  alias Omunculus.Store
  alias Omunculus.Tool.Views

  @scope %{
    run_id: nil,
    work_id: nil,
    request_id: nil,
    inbox_id: nil,
    prompt_id: nil,
    args: %{},
    computed: %{}
  }

  defp hydrate(conn, views, scope) do
    {:ok, specs} = Views.parse(views)
    Views.hydrate(conn, specs, Map.merge(@scope, scope))
  end

  defp child(conn, parent_id, title, state, updated_at) do
    Fixtures.insert(conn, :works, %{
      parent_id: parent_id,
      title: title,
      state: state,
      updated_at: updated_at
    })
  end

  test "works reads the work, its parent and its children by state", %{conn: conn} do
    root = Fixtures.insert(conn, :works, %{title: "root"})
    done = child(conn, root, "done one", "done", "2026-01-01T00:00:01Z")
    child(conn, root, "open one", "open", "2026-01-01T00:00:02Z")

    views = %{
      "self" => %{"source" => "works"},
      "parent" => %{"source" => "works", "relation" => "parent"},
      "closed" => %{"source" => "works", "relation" => "children", "state" => ["done"]}
    }

    assert {:ok, %{"self" => %{title: "root"}, "parent" => nil, "closed" => [%{id: ^done}]}} =
             hydrate(conn, views, %{work_id: root})

    assert {:ok, %{"parent" => %{id: ^root}}} = hydrate(conn, views, %{work_id: done})
  end

  test "children since the last run are those changed after the work's last closed run",
       %{conn: conn} do
    root = Fixtures.insert(conn, :works)
    child(conn, root, "before", "done", "2026-01-01T00:00:01Z")
    run = Fixtures.open_run(conn, %{work_id: root})
    {:ok, _} = Store.close_run(conn, run.id)
    {:ok, closed} = Store.view(conn, "run", run.id)
    child(conn, root, "after", "done", closed.finished_at <> "1")

    views = %{
      "results" => %{
        "source" => "works",
        "relation" => "children",
        "since" => "last_run",
        "include" => ["last_comment"]
      }
    }

    assert {:ok, %{"results" => [%{title: "after", last_comment: nil}]}} =
             hydrate(conn, views, %{work_id: root})
  end

  test "includes add each work's last comment, comments and closed runs", %{conn: conn} do
    root = Fixtures.insert(conn, :works)
    work = child(conn, root, "child", "done", "2026-01-01T00:00:01Z")

    Fixtures.insert(conn, :comments, %{
      work_id: work,
      body: "first",
      created_at: "2026-01-01T00:00:01Z"
    })

    Fixtures.insert(conn, :comments, %{
      work_id: work,
      body: "report",
      created_at: "2026-01-01T00:00:02Z"
    })

    views = %{
      "children" => %{
        "source" => "works",
        "relation" => "children",
        "include" => ["last_comment", "comments", "runs"]
      }
    }

    assert {:ok, %{"children" => [read]}} = hydrate(conn, views, %{work_id: root})
    assert read.last_comment.body == "report"
    assert Enum.map(read.comments, & &1.body) == ["first", "report"]
    assert read.runs == []
  end

  test "a work named by an argument is read only when it descends from the call's work",
       %{conn: conn} do
    root = Fixtures.insert(conn, :works)
    middle = child(conn, root, "middle", "waiting", "2026-01-01T00:00:01Z")
    below = child(conn, middle, "below", "done", "2026-01-01T00:00:02Z")
    other = Fixtures.insert(conn, :works, %{title: "elsewhere"})

    views = %{
      "target" => %{"source" => "works", "from" => ["args.work_id"], "within" => "descendants"}
    }

    assert {:ok, %{"target" => %{title: "below"}}} =
             hydrate(conn, views, %{work_id: root, args: %{"work_id" => below}})

    assert {:error, {:outside, ^other}} =
             hydrate(conn, views, %{work_id: root, args: %{"work_id" => other}})

    assert {:error, {:outside, ^root}} =
             hydrate(conn, views, %{work_id: middle, args: %{"work_id" => root}})

    # A person's call, outside any run and work, reads the work it names.
    assert {:ok, %{"target" => %{title: "elsewhere"}}} =
             hydrate(conn, views, %{work_id: nil, args: %{"work_id" => other}})
  end

  test "events with the cause relation read the event that made the run due", %{conn: conn} do
    cause = Fixtures.insert(conn, :events, %{type: "continue", sequence: 1})
    run = Fixtures.insert(conn, :runs, %{cause_id: cause})
    views = %{"cause" => %{"source" => "events", "relation" => "cause"}}

    assert {:ok, %{"cause" => %{id: ^cause, type: "continue"}}} =
             hydrate(conn, views, %{run_id: run})
  end

  test "a view whose anchors are all absent is left out", %{conn: conn} do
    views = %{"comments" => %{"source" => "comments"}, "work" => %{"source" => "works"}}
    assert {:ok, %{}} == hydrate(conn, views, %{})
  end
end
