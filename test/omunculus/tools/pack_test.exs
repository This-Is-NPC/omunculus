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

  test "says what the pack needs before importing anything", %{dir: dir, config_path: config_path} do
    File.mkdir_p!(Path.join([dir, "team", "environment", ".state"]))
    assert %{"ok" => false, "output" => output} = pack(config_path, %{"models" => "lead=fast"})
    assert output =~ "auth needed for: vault"
    assert output =~ "environment, to run yourself: up in"
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

  test "refuses a pack whose required tools the project lacks, saying where to get them", %{
    dir: dir,
    config_path: config_path
  } do
    toml = Path.join([dir, "team", "pack.toml"])
    original = File.read!(toml)

    requiring = fn tool ->
      String.replace(
        original,
        ~s(auth = ["vault"]),
        ~s(auth = ["vault"]\n\n[pack.requires]\n#{tool} = "the shell pack"\n)
      )
    end

    File.write!(toml, requiring.("bash"))

    assert %{"ok" => false, "output" => output} =
             pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine"})

    assert output ==
             "pack team requires tools the project lacks: bash (the shell pack); " <>
               "add a [tools] path that holds them or import the pack that brings them"

    refute Map.has_key?(Toml.decode_file!(config_path), "packs")

    # Once the project has it, loading the config with the pack checks it again.
    File.write!(toml, requiring.("end"))
    assert %{"ok" => true} = pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine"})
    File.write!(toml, requiring.("bash"))
    assert {:error, {:packs, {"team", :requires, %{"bash" => _}}}} = Config.load(config_path)
  end

  test "refuses a pack whose requires gives no place to get a tool", %{
    dir: dir,
    config_path: config_path
  } do
    toml = Path.join([dir, "team", "pack.toml"])

    File.write!(
      toml,
      String.replace(
        File.read!(toml),
        ~s(auth = ["vault"]),
        ~s(auth = ["vault"]\nrequires = ["end"])
      )
    )

    assert %{"ok" => false, "output" => output} =
             pack(config_path, %{"models" => "lead=fast", "auth" => "vault=mine"})

    assert output =~ ~s({"team", :requires, :invalid})
  end

  test "the builtin catalog discovers pack for the command line and a reply's chain" do
    assert %{"pack" => %{triggers: ["cli", "chain"]}} = Omunculus.Tool.Catalog.unconfigured()
  end
end
