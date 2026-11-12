defmodule Omunculus.Tools.PatchTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Patch

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "one\ntwo\nthree\n")
    File.write!(Path.join(root, "b.txt"), "x\ny\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp patch(root, body, view \\ %{}) do
    input = %{
      name: "patch",
      args: %{"patch" => "*** Begin Patch\n" <> body <> "*** End Patch"},
      view: view,
      run_id: nil,
      work_id: nil,
      workspace: nil,
      roots: [root]
    }

    Patch.run(input, ExecutionPolicyFixtures.policy([root], writable: true))
  end

  defp failed(output), do: %{"ok" => false, "output" => output, "emit" => []}

  test "adds, updates and deletes files in one call", %{root: root} do
    assert %{"ok" => true, "output" => output} =
             patch(
               root,
               "*** Add File: sub/new.txt\n+hello\n+world\n" <>
                 "*** Update File: a.txt\n@@\n one\n-two\n+2\n+2b\n three\n" <>
                 "*** Delete File: b.txt\n"
             )

    assert output == "added sub/new.txt\nupdated a.txt\ndeleted b.txt"
    assert File.read!(Path.join(root, "sub/new.txt")) == "hello\nworld\n"
    assert File.read!(Path.join(root, "a.txt")) == "one\n2\n2b\nthree\n"
    refute File.exists?(Path.join(root, "b.txt"))
  end

  test "writes nothing when one section fails", %{root: root} do
    assert patch(
             root,
             "*** Add File: new.txt\n+hi\n*** Update File: a.txt\n@@\n-zzz\n+q\n"
           ) == failed("a.txt: hunk[1]: old text not found")

    refute File.exists?(Path.join(root, "new.txt"))
    assert File.read!(Path.join(root, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "refuses what it cannot apply", %{root: root} do
    for {body, output} <- [
          {"*** Add File: a.txt\n+hi\n", "a.txt: file exists; update it instead"},
          {"*** Delete File: nope.txt\n", "no such file: nope.txt"},
          {"*** Update File: ../x.txt\n@@\n-a\n+b\n", "path outside roots: ../x.txt"},
          {"*** Delete File: a.txt\n*** Delete File: a.txt\n",
           "a.txt: the patch names this file twice"},
          {"*** Update File: a.txt\n@@\n+only\n",
           "a hunk needs a context or removed line to find its place"},
          {"*** Update File: a.txt\n@@\n?bad\n", "a hunk line starts with a space, - or +: ?bad"},
          {"*** Update File: a.txt\n", "an updated file needs at least one hunk"}
        ] do
      assert patch(root, body) == failed(output), body
    end

    assert patch(root, "") == failed("the patch has no file section")
    assert File.read!(Path.join(root, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "refuses a file that changed since the run last read it", %{root: root} do
    read = %{
      type: "tool",
      at: DateTime.utc_now() |> DateTime.add(-10) |> DateTime.to_iso8601(),
      body: Jason.encode!(%{"name" => "read", "ok" => true, "args" => %{"path" => "a.txt"}})
    }

    assert patch(root, "*** Update File: a.txt\n@@\n-one\n+1\n", %{"run" => [read]}) ==
             failed("a.txt changed since you last read it: read it again, then edit")
  end

  test "the builtin catalog discovers patch in fs.write" do
    assert %{"patch" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.write"]
  end
end
