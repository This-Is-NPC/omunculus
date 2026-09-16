defmodule Omunculus.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke, Manifest}
  alias Omunculus.Tools.Bash

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "bash",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "runs a command at the root and captures its output", %{root: root} do
    input = %{@input | args: %{"command" => "echo hi"}, roots: [root]}

    assert Bash.run(input) == %{"ok" => true, "output" => "hi\n", "emit" => []}
  end

  test "runs the command inside the first root", %{root: root} do
    File.write!(Path.join(root, "marker"), "")
    input = %{@input | args: %{"command" => "ls"}, roots: [root]}

    assert %{"ok" => true, "output" => output} = Bash.run(input)
    assert output =~ "marker"
  end

  test "a non-zero exit fails and appends the exit status", %{root: root} do
    input = %{@input | args: %{"command" => "exit 3"}, roots: [root]}

    assert Bash.run(input) == %{"ok" => false, "output" => "\n(exit 3)", "emit" => []}
  end

  test "refuses without roots" do
    input = %{@input | args: %{"command" => "echo hi"}, roots: []}

    assert Bash.run(input) == %{"ok" => false, "output" => "no root", "emit" => []}
  end

  test "refuses without a command", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Bash.run(input) == %{"ok" => false, "output" => "command required", "emit" => []}
  end

  test "the builtin catalog never discovers bash" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    refute Map.has_key?(catalog, "bash")
  end

  test "the codex-like preset's manifest wires bash to this module", %{root: root} do
    path = Path.join(:code.priv_dir(:omunculus), "presets/codex-like/tools/bash/tool.toml")

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.name == "bash"
    assert manifest.module == "Omunculus.Tools.Bash"
    assert manifest.triggers == ["model"]

    input = %{@input | args: %{"command" => "echo hi"}, roots: [root]}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Bash.run(input)["output"]
  end
end
