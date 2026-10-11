defmodule Omunculus.Tools.PackTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Fixtures}
  alias Omunculus.Tools.Pack

  setup do
    dir = Fixtures.tmp_dir()
    Fixtures.pack(dir)
    %{dir: dir, config_path: Fixtures.write_pack_config(dir)}
  end

  defp pack(config_path, args),
    do: Pack.run(%{args: Map.put(args, "path", "team"), config_path: config_path})

  test "says what the pack needs before importing anything", %{config_path: config_path} do
    assert %{"ok" => false, "output" => output} = pack(config_path, %{"models" => "lead=fast"})
    assert output =~ "auth needed for: vault"
    assert output =~ "environment, to run yourself: up"
    refute Map.has_key?(Toml.decode_file!(config_path), "packs")
  end

  test "imports the pack and copies its workspace, keeping the project's files",
       %{dir: dir, config_path: config_path} do
    # Without workspaces, the project's root is the config's folder.
    root = dir
    File.write!(Path.join(root, "AGENTS.md"), "# Ours\n")
    File.write!(Path.join([dir, "team", "workspace", "README.md"]), "# Team\n")

    assert %{"ok" => true, "output" => output} =
             pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine"})

    assert output =~ "imported team"
    assert output =~ "copied README.md; kept the project's AGENTS.md"
    assert File.read!(Path.join(root, "AGENTS.md")) == "# Ours\n"

    assert {:ok, %{agents: %{"chief" => %{model: "fast"}}}} = Config.load(config_path)

    assert %{"ok" => true} =
             pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine", "depth" => "1"})

    assert {:ok, %{agents: %{"chief" => %{depth: 1}}}} = Config.load(config_path)

    # Again, the entry for the same folder is replaced, not added.
    assert %{"ok" => true} = pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine"})
    assert [%{"path" => "team"}] = Toml.decode_file!(config_path)["packs"]
  end

  test "the builtin catalog discovers pack for the command line" do
    assert %{"pack" => %{triggers: ["cli"]}} = Omunculus.Tool.Catalog.unconfigured()
  end
end
