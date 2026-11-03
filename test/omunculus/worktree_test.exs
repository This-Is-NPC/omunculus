defmodule Omunculus.WorktreeTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Fixtures, Harness, Worktree}
  alias Omunculus.Store.Actions.Helpers
  alias Omunculus.Store.{Events, Query}

  setup do
    dir = Fixtures.tmp_dir()
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    commit!(repo, "first")

    Fixtures.write_config(dir, """
    [workspaces.app]
    root = "#{repo}"

    [policy]
    workspace = "app"

    [agents.concierge]
    depth = 0
    text = "c"

    [agents.worker]
    depth = 1
    text = "w"

    [workflows.delivery]
    isolate = "worktree"
    steps = [{ name = "to_do", agent = "worker" }]

    [workflows.plain]
    steps = [{ name = "to_do", agent = "worker" }]
    """)

    project = Fixtures.open_project(dir)
    {:ok, config} = Fixtures.load_config(dir)
    %{dir: dir, repo: repo, project: project, config: config}
  end

  defp git!(cd, args) do
    {said, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    said
  end

  defp commit!(cd, message) do
    git!(cd, ["add", "--all"])
    git!(cd, ["commit", "--quiet", "-m", message])
  end

  defp work(project, id, workflow, parent_id \\ nil) do
    :ok =
      Helpers.insert_work(project.conn, %{
        id: id,
        parent_id: parent_id,
        event_id: nil,
        workspace: "app",
        assignee: "worker",
        workflow: workflow,
        stage: "to_do",
        title: "t",
        goal: "g",
        at: Events.now()
      })

    {:ok, row} = Omunculus.Store.view(project.conn, "work", id)
    row
  end

  defp set_state(project, id, state) do
    :ok = Query.exec(project.conn, "UPDATE works SET state = ? WHERE id = ?", [state, id])
  end

  test "an isolating work's root is its worktree; others keep the workspace's", ctx do
    isolated = work(ctx.project, "w1", "delivery")
    plain = work(ctx.project, "w2", "plain")

    assert Harness.workspace_context(ctx.config, isolated, nil).root ==
             Path.join([ctx.repo, ".omunculus-worktrees", "w1"])

    assert Harness.workspace_context(ctx.config, plain, nil).root == ctx.repo
    assert Harness.workspace_context(ctx.config, nil, nil).root == ctx.repo
  end

  test "prepare creates the worktree on work/<id> from HEAD and keeps it out of the repository",
       ctx do
    row = work(ctx.project, "w1", "delivery")
    path = Harness.workspace_context(ctx.config, row, nil).root

    assert :ok = Worktree.prepare(ctx.project.conn, ctx.config, row, path)
    assert File.read!(Path.join(path, "a.txt")) == "one\n"
    assert git!(path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "work/w1\n"
    assert git!(ctx.repo, ["status", "--porcelain"]) == ""

    assert :ok = Worktree.prepare(ctx.project.conn, ctx.config, row, path)

    exclude = Path.join([ctx.repo, ".git", "info", "exclude"])

    assert exclude
           |> File.read!()
           |> String.split("\n")
           |> Enum.count(&(&1 == ".omunculus-worktrees/")) == 1
  end

  test "a plain work gets no worktree", ctx do
    row = work(ctx.project, "w2", "plain")

    assert :ok =
             Worktree.prepare(ctx.project.conn, ctx.config, row, Worktree.path(ctx.repo, "w2"))

    refute File.exists?(Worktree.dir(ctx.repo))
  end

  test "a child starts from its isolated parent's branch", ctx do
    parent = work(ctx.project, "p1", "delivery")
    parent_path = Worktree.path(ctx.repo, "p1")
    :ok = Worktree.prepare(ctx.project.conn, ctx.config, parent, parent_path)
    File.write!(Path.join(parent_path, "b.txt"), "parent\n")
    commit!(parent_path, "parent change")

    child = work(ctx.project, "c1", "delivery", "p1")
    child_path = Worktree.path(ctx.repo, "c1")
    assert :ok = Worktree.prepare(ctx.project.conn, ctx.config, child, child_path)
    assert File.read!(Path.join(child_path, "b.txt")) == "parent\n"
  end

  test "a child of a plain parent starts from the workspace's HEAD", ctx do
    work(ctx.project, "p1", "plain")
    child = work(ctx.project, "c1", "delivery", "p1")
    path = Worktree.path(ctx.repo, "c1")
    assert :ok = Worktree.prepare(ctx.project.conn, ctx.config, child, path)
    assert File.exists?(Path.join(path, "a.txt"))
  end

  test "remove commits what the work left, drops the worktree and keeps the branch", ctx do
    row = work(ctx.project, "w1", "delivery")
    path = Worktree.path(ctx.repo, "w1")
    :ok = Worktree.prepare(ctx.project.conn, ctx.config, row, path)
    File.write!(Path.join(path, "new.txt"), "left\n")

    assert :ok = Worktree.remove(path)
    refute File.exists?(path)
    assert git!(ctx.repo, ["show", "work/w1:new.txt"]) == "left\n"
    assert :ok = Worktree.remove(path)

    assert :ok = Worktree.prepare(ctx.project.conn, ctx.config, row, path)
    assert File.read!(Path.join(path, "new.txt")) == "left\n"
  end

  test "settled lists ended isolated works with no run open", ctx do
    work(ctx.project, "w1", "delivery")
    work(ctx.project, "w2", "delivery")
    work(ctx.project, "w3", "plain")
    set_state(ctx.project, "w2", "done")
    set_state(ctx.project, "w3", "done")

    assert {:ok, [%{id: "w2"}]} = Omunculus.Store.settled(ctx.project.conn, ctx.config.isolated)

    set_state(ctx.project, "w1", "cancelled")

    assert {:ok, settled} = Omunculus.Store.settled(ctx.project.conn, ctx.config.isolated)
    assert Enum.sort(Enum.map(settled, & &1.id)) == ["w1", "w2"]
  end

  test "a workspace that is not a git repository refuses the work", ctx do
    plain = Path.join(ctx.dir, "plain")
    File.mkdir_p!(plain)
    row = work(ctx.project, "w1", "delivery")

    assert {:error, {:worktree, message}} =
             Worktree.prepare(ctx.project.conn, ctx.config, row, Worktree.path(plain, "w1"))

    assert message =~ "root of a git repository"

    sub = Path.join(ctx.repo, "sub")
    File.mkdir_p!(sub)

    assert {:error, {:worktree, _}} =
             Worktree.prepare(ctx.project.conn, ctx.config, row, Worktree.path(sub, "w1"))
  end

  describe "merge" do
    setup ctx do
      row = work(ctx.project, "w1", "delivery")
      path = Worktree.path(ctx.repo, "w1")
      :ok = Worktree.prepare(ctx.project.conn, ctx.config, row, path)
      %{path: path}
    end

    test "brings the branch into the root", ctx do
      File.write!(Path.join(ctx.path, "child.txt"), "child\n")
      :ok = Worktree.remove(ctx.path)

      assert {:ok, _said} = Worktree.merge(ctx.repo, "w1")
      assert File.read!(Path.join(ctx.repo, "child.txt")) == "child\n"
    end

    test "a conflict is aborted and names its paths", ctx do
      File.write!(Path.join(ctx.path, "a.txt"), "child\n")
      :ok = Worktree.remove(ctx.path)
      File.write!(Path.join(ctx.repo, "a.txt"), "parent\n")
      commit!(ctx.repo, "parent edit")

      assert {:conflict, ["a.txt"]} = Worktree.merge(ctx.repo, "w1")
      assert File.read!(Path.join(ctx.repo, "a.txt")) == "parent\n"
      assert git!(ctx.repo, ["status", "--porcelain"]) == ""
      refute File.exists?(Path.join([ctx.repo, ".git", "MERGE_HEAD"]))
    end

    test "a work without a branch is an error", ctx do
      assert {:error, message} = Worktree.merge(ctx.repo, "nobody")
      assert is_binary(message)
    end
  end
end
