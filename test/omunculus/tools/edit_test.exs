defmodule Omunculus.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Edit

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    File.write!(Path.join(root, "file.txt"), "hello world\n")
    File.write!(Path.join(root, "dup.txt"), "same same\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "edit",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  defp edit(root, path, edits, view \\ %{}) do
    input = %{
      @input
      | args: %{
          "path" => path,
          "edits" => Enum.map(edits, fn {o, n} -> %{"old" => o, "new" => n} end)
        },
        roots: [root],
        view: view
    }

    Edit.run(input, policy(input))
  end

  defp failed(output), do: %{"ok" => false, "output" => output, "emit" => []}

  test "applies every edit against the file as it was", %{root: root} do
    assert edit(root, "file.txt", [{"world", "there"}, {"hello", "hi"}]) ==
             %{"ok" => true, "output" => "", "emit" => []}

    assert File.read!(Path.join(root, "file.txt")) == "hi there\n"
  end

  test "refuses them all when one is missing, repeated, overlapping or the same", %{root: root} do
    for {path, edits, output} <- [
          {"file.txt", [{"world", "x"}, {"missing", "x"}], "edits[2]: old text not found"},
          {"dup.txt", [{"same", "x"}], "edits[1]: old text is ambiguous: 2 matches"},
          {"file.txt", [{"hello wo", "x"}, {"world", "y"}], "edits[1] and edits[2] overlap"},
          {"file.txt", [{"world", "world"}], "edits[1]: new is the same as old"}
        ] do
      assert edit(root, path, edits) == failed(output)
    end

    assert File.read!(Path.join(root, "file.txt")) == "hello world\n"
  end

  test "keeps CRLF line endings and a byte order mark", %{root: root} do
    File.write!(Path.join(root, "win.txt"), "﻿one\r\ntwo\r\n")

    assert %{"ok" => true} = edit(root, "win.txt", [{"one\ntwo", "uno\r\ndos"}])
    assert File.read!(Path.join(root, "win.txt")) == "﻿uno\r\ndos\r\n"
  end

  test "refuses a file that changed since the run last read it", %{root: root} do
    read_at = fn seconds ->
      %{
        type: "tool",
        at: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601(),
        body: Jason.encode!(%{"name" => "read", "ok" => true, "args" => %{"path" => "file.txt"}})
      }
    end

    assert edit(root, "file.txt", [{"world", "x"}], %{"run" => [read_at.(-10)]}) ==
             failed("file.txt changed since you last read it: read it again, then edit")

    assert %{"ok" => true} = edit(root, "file.txt", [{"world", "x"}], %{"run" => [read_at.(10)]})
  end

  test "refuses what it cannot apply", %{root: root} do
    for {args, output} <- [
          {%{"path" => "file.txt"}, "edits required: a list of {old, new}"},
          {%{"path" => "file.txt", "edits" => [%{"old" => "", "new" => "b"}]},
           "each edit needs a non-empty old and a new"},
          {%{"edits" => [%{"old" => "a", "new" => "b"}]}, "path required"},
          {%{"path" => "../escape.txt", "edits" => [%{"old" => "a", "new" => "b"}]},
           "path outside roots: ../escape.txt"},
          {%{"path" => "missing.txt", "edits" => [%{"old" => "a", "new" => "b"}]},
           "no such file: missing.txt"}
        ] do
      input = %{@input | args: args, roots: [root]}
      assert Edit.run(input, policy(input)) == failed(output), inspect(args)
    end
  end

  test "the builtin catalog discovers edit with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"edit" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.write"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    File.write!(Path.join(root, "wired.txt"), "hello world\n")
    manifest = Map.fetch!(Catalog.unconfigured(), "edit")

    input = %{
      @input
      | args: %{"path" => "wired.txt", "edits" => [%{"old" => "hello", "new" => "hi"}]},
        roots: [root]
    }

    assert {:ok, result} = Invoke.call(manifest, input, policy(input))
    assert result.output == ""
    assert File.read!(Path.join(root, "wired.txt")) == "hi world\n"
  end

  defp policy(input), do: ExecutionPolicyFixtures.policy(input.roots, writable: true)
end
