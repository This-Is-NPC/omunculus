defmodule Omunculus.Tools.PresetTest do
  use ExUnit.Case, async: true

  alias Omunculus.Config
  alias Omunculus.Fixtures
  alias Omunculus.Tools.{Out, Preset}

  setup do
    root = Fixtures.tmp_dir()
    %{root: root}
  end

  defp from(name), do: Fixtures.preset_dir(name)

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
    assert Preset.run(input(root, %{"name" => "codex-like", "from" => from("codex-like")})) == %{
             "ok" => true,
             "output" => Out.preset_applied("codex-like"),
             "emit" => []
           }

    assert File.read!(Path.join(root, "omunculus.toml")) =~ "agents.codex"
    assert File.read!(Path.join([root, "tools", "bash", "tool.toml"])) =~ ~s(name = "bash")

    {:ok, config} = Config.load(Path.join(root, "omunculus.toml"))
    assert Fixtures.package_tools() in config.tools.paths
    assert Path.join(from("codex-like"), "tools") in config.tools.paths
    assert Path.join(root, "tools") in config.tools.paths
    assert Enum.all?(config.tools.paths, &(Path.type(&1) == :absolute))
    assert config.execution.sandbox.script == Application.app_dir(:omunculus, "priv/sandbox.js")
  end

  test "applying codex-like overwrites an existing omunculus.toml", %{root: root} do
    File.write!(Path.join(root, "omunculus.toml"), "stale")

    assert Preset.run(input(root, %{"name" => "codex-like", "from" => from("codex-like")}))["ok"] ==
             true

    refute File.read!(Path.join(root, "omunculus.toml")) == "stale"
  end

  test "applying pi-like writes no bash tool", %{root: root} do
    assert Preset.run(input(root, %{"name" => "pi-like", "from" => from("pi-like")})) == %{
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

    assert Preset.run(%{
             input(root, %{"name" => "default", "from" => from("default")})
             | config_path: path
           })["ok"] == true

    assert File.regular?(path)
    refute File.exists?(Path.join(root, "omunculus.toml"))
  end

  test "applying default brings the system team, the steward with its skills", %{root: root} do
    path = Path.join(root, "omunculus.toml")

    assert %{"ok" => true} =
             Preset.run(%{
               args: %{"name" => "default", "from" => from("default")},
               config_path: path
             })

    assert {:ok, config} = Config.load(path)
    assert %{depth: 0} = config.agents["steward"]

    skills = config.tools.skills |> Omunculus.Skills.discover() |> Map.keys()
    assert Enum.all?(~w(team-design team-composition configure), &(("skill." <> &1) in skills))
  end

  test "a pack the preset imports is found from the preset's folder", %{root: root} do
    from = Path.join(root, "preset")
    File.mkdir_p!(from)
    File.write!(Path.join(from, "omunculus.toml"), "[[packs]]\npath = \"packs/team\"\n")
    path = Path.join(root, "omunculus.toml")

    assert %{"ok" => true} =
             Preset.run(%{args: %{"name" => "mine", "from" => from}, config_path: path})

    assert [%{"path" => found}] = Toml.decode_file!(path)["packs"]
    assert found == Path.join(from, "packs/team")
  end

  test "an unknown preset fails and writes nothing", %{root: root} do
    assert Preset.run(input(root, %{"name" => "nope", "from" => Path.join(root, "missing")})) ==
             %{
               "ok" => false,
               "output" => "unknown preset: nope",
               "emit" => []
             }

    refute File.exists?(Path.join(root, "omunculus.toml"))
  end

  test "refuses without a name", %{root: root} do
    assert Preset.run(input(root, %{"from" => from("default")})) == %{
             "ok" => false,
             "output" => "name required",
             "emit" => []
           }
  end

  test "refuses without from", %{root: root} do
    assert Preset.run(input(root, %{"name" => "default"})) == %{
             "ok" => false,
             "output" => "from required",
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
