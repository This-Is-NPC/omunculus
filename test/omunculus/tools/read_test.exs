defmodule Omunculus.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Omunculus.ExecutionPolicyFixtures
  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{Out, Read}

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    File.write!(Path.join(root, "file.txt"), "hello\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "read",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "reads a file inside the root", %{root: root} do
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert Read.run(input, policy(input)) == %{"ok" => true, "output" => "hello\n", "emit" => []}
  end

  test "refuses a file that is not text, saying its size", %{root: root} do
    File.write!(Path.join(root, "call.wav"), <<82, 73, 70, 70, 228, 93, 0, 0>>)
    input = %{@input | args: %{"path" => "call.wav"}, roots: [root]}

    assert Read.run(input, policy(input)) == Out.fail(Out.not_text("call.wav", 8))
  end

  test "offset and limit read those lines and say which of how many", %{root: root} do
    File.write!(Path.join(root, "lines.txt"), "one\ntwo\nthree\nfour")

    read = fn args ->
      input = %{@input | args: Map.put(args, "path", "lines.txt"), roots: [root]}
      Read.run(input, policy(input))["output"]
    end

    assert read.(%{"offset" => 2, "limit" => 2}) == "two\nthree\n(lines 2-3 of 4)"
    assert read.(%{"offset" => 3}) == "three\nfour\n(lines 3-4 of 4)"
    assert read.(%{"limit" => 1}) == "one\n(lines 1-1 of 4)"
    assert read.(%{"limit" => 9}) == "one\ntwo\nthree\nfour\n(lines 1-4 of 4)"
  end

  test "refuses an offset past the last line or a count that is not positive", %{root: root} do
    read = fn args ->
      input = %{@input | args: Map.put(args, "path", "file.txt"), roots: [root]}
      Read.run(input, policy(input))
    end

    assert %{"ok" => false, "output" => "offset 2 is past the last line, 1"} =
             read.(%{"offset" => 2})

    assert %{"ok" => false, "output" => "offset must be a positive integer"} =
             read.(%{"offset" => 0})

    assert %{"ok" => false, "output" => "limit must be a positive integer"} =
             read.(%{"limit" => "3"})
  end

  test "refuses a path outside the root", %{root: root} do
    input = %{@input | args: %{"path" => "../escape.txt"}, roots: [root]}

    assert Read.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "path outside roots: ../escape.txt",
             "emit" => []
           }
  end

  test "refuses without a path", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Read.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "path required",
             "emit" => []
           }
  end

  test "reports a missing file", %{root: root} do
    input = %{@input | args: %{"path" => "missing.txt"}, roots: [root]}

    assert Read.run(input, policy(input)) == %{
             "ok" => false,
             "output" => "no such file: missing.txt",
             "emit" => []
           }
  end

  test "the builtin catalog discovers read with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"read" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["fs.read"]
  end

  test "the manifest wiring yields the same result as calling the module directly", %{
    root: root
  } do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "read")
    input = %{@input | args: %{"path" => "file.txt"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input, policy(input))
    assert result.output == Read.run(input, policy(input))["output"]
  end

  defp policy(input), do: ExecutionPolicyFixtures.policy(input.roots)
end
