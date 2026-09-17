defmodule Omunculus.Tools.PresetTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.{Out, Preset}

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp input(root, args) do
    %{
      name: "preset",
      args: args,
      view: %{},
      run_id: nil,
      work_id: nil,
      workspace: nil,
      roots: [root],
      config_path: Path.join(root, "omunculus.toml")
    }
  end

  test "applying codex-like writes the TOML and the bash tool folder", %{root: root} do
    assert Preset.run(input(root, %{"name" => "codex-like"})) == %{
             "ok" => true,
             "output" => Out.preset_applied("codex-like"),
             "emit" => []
           }

    assert File.read!(Path.join(root, "omunculus.toml")) =~ "agents.codex"
    assert File.read!(Path.join([root, "tools", "bash", "tool.toml"])) =~ ~s(name = "bash")
  end

  test "applying codex-like overwrites an existing omunculus.toml", %{root: root} do
    File.write!(Path.join(root, "omunculus.toml"), "stale")

    assert Preset.run(input(root, %{"name" => "codex-like"}))["ok"] == true
    refute File.read!(Path.join(root, "omunculus.toml")) == "stale"
  end

  test "applying pi-like writes no bash tool", %{root: root} do
    assert Preset.run(input(root, %{"name" => "pi-like"})) == %{
             "ok" => true,
             "output" => Out.preset_applied("pi-like"),
             "emit" => []
           }

    assert File.read!(Path.join(root, "omunculus.toml")) =~ "agents.pi"
    refute File.exists?(Path.join([root, "tools", "bash"]))
    refute File.dir?(Path.join(root, "tools"))
  end

  test "writes the chosen config path, not a fixed filename in roots", %{root: root} do
    path = Path.join(root, "named.toml")

    assert Preset.run(%{input(root, %{"name" => "default"}) | config_path: path})["ok"] == true
    assert File.regular?(path)
    refute File.exists?(Path.join(root, "omunculus.toml"))
  end

  test "an unknown preset fails and writes nothing", %{root: root} do
    assert Preset.run(input(root, %{"name" => "nope"})) == %{
             "ok" => false,
             "output" => "unknown preset: nope",
             "emit" => []
           }

    refute File.exists?(Path.join(root, "omunculus.toml"))
  end

  test "refuses without a name", %{root: root} do
    assert Preset.run(input(root, %{})) == %{
             "ok" => false,
             "output" => "name required",
             "emit" => []
           }
  end

  test "refuses without a config_path", %{root: root} do
    input = Map.delete(input(root, %{"name" => "default"}), :config_path)

    assert Preset.run(input) == %{
             "ok" => false,
             "output" => "config_path required",
             "emit" => []
           }
  end
end
