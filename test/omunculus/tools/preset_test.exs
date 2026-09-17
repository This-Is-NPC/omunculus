defmodule Omunculus.Tools.PresetTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.{Out, Preset}

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @input %{
    name: "preset",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "applying codex-like writes the TOML and the bash tool folder", %{root: root} do
    input = %{@input | args: %{"name" => "codex-like"}, roots: [root]}

    assert Preset.run(input) == %{
             "ok" => true,
             "output" => Out.preset_applied("codex-like"),
             "emit" => []
           }

    assert File.read!(Path.join(root, "omunculus.toml")) =~ "agents.codex"
    assert File.read!(Path.join([root, "tools", "bash", "tool.toml"])) =~ ~s(name = "bash")
  end

  test "applying codex-like overwrites an existing omunculus.toml", %{root: root} do
    File.write!(Path.join(root, "omunculus.toml"), "stale")
    input = %{@input | args: %{"name" => "codex-like"}, roots: [root]}

    assert Preset.run(input)["ok"] == true
    refute File.read!(Path.join(root, "omunculus.toml")) == "stale"
  end

  test "applying pi-like writes no bash tool", %{root: root} do
    input = %{@input | args: %{"name" => "pi-like"}, roots: [root]}

    assert Preset.run(input) == %{
             "ok" => true,
             "output" => Out.preset_applied("pi-like"),
             "emit" => []
           }

    assert File.read!(Path.join(root, "omunculus.toml")) =~ "agents.pi"
    refute File.exists?(Path.join([root, "tools", "bash"]))
    refute File.dir?(Path.join(root, "tools"))
  end

  test "an unknown preset fails and writes nothing", %{root: root} do
    input = %{@input | args: %{"name" => "nope"}, roots: [root]}

    assert Preset.run(input) == %{"ok" => false, "output" => "unknown preset: nope", "emit" => []}
    refute File.exists?(Path.join(root, "omunculus.toml"))
  end

  test "refuses without a name", %{root: root} do
    input = %{@input | args: %{}, roots: [root]}

    assert Preset.run(input) == %{"ok" => false, "output" => "name required", "emit" => []}
  end
end
