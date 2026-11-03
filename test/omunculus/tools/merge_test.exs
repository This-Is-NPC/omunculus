defmodule Omunculus.Tools.MergeTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tools.Merge

  setup do
    root = Omunculus.Fixtures.tmp_dir()
    git!(root, ["init", "--quiet", "-b", "main"])
    File.write!(Path.join(root, "a.txt"), "one\n")
    commit!(root, "first")
    git!(root, ["checkout", "--quiet", "-b", "work/w1"])
    File.write!(Path.join(root, "a.txt"), "child\n")
    File.write!(Path.join(root, "b.txt"), "child\n")
    commit!(root, "child")
    git!(root, ["checkout", "--quiet", "main"])
    %{root: root}
  end

  defp git!(cd, args) do
    {said, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    said
  end

  defp commit!(cd, message) do
    git!(cd, ["add", "--all"])
    git!(cd, ["commit", "--quiet", "-m", message])
  end

  defp input(root, view), do: %{args: %{"work_id" => "w1"}, view: view, roots: [root]}

  defp view(state \\ "done", parent \\ "p"),
    do: %{
      "own" => %{id: "p"},
      "target" => %{id: "w1", parent_id: parent, state: state}
    }

  defp policy(root, writable \\ true),
    do: ExecutionPolicyFixtures.policy([root], writable: writable)

  test "merges the branch of a done child into the root", %{root: root} do
    assert %{"ok" => true} = Merge.run(input(root, view()), policy(root))
    assert File.read!(Path.join(root, "b.txt")) == "child\n"
  end

  test "a conflict fails naming the paths and merges nothing", %{root: root} do
    File.write!(Path.join(root, "a.txt"), "parent\n")
    commit!(root, "parent")

    assert %{"ok" => false, "output" => output} = Merge.run(input(root, view()), policy(root))
    assert output =~ "conflict in: a.txt"
    refute File.exists?(Path.join(root, "b.txt"))
    assert git!(root, ["status", "--porcelain"]) == ""
  end

  test "refuses a work that is not a done child, or a root not writable", %{root: root} do
    assert %{"ok" => false, "output" => "work_id must name a done work" <> _} =
             Merge.run(input(root, view("open")), policy(root))

    assert %{"ok" => false, "output" => "work_id must name a done work" <> _} =
             Merge.run(input(root, view("done", "other")), policy(root))

    assert %{"ok" => false, "output" => "work_id must name a work below this run's"} =
             Merge.run(input(root, %{}), policy(root))

    assert %{"ok" => false, "output" => "the workspace is not writable"} =
             Merge.run(input(root, view()), policy(root, false))
  end
end
