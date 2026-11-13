defmodule Omunculus.OmupackTest do
  use ExUnit.Case, async: true

  alias Omunculus.{Config, Fixtures}
  alias Omunculus.Config.Packs
  alias Omunculus.Config.Toml, as: Encoder
  alias Omunculus.Tools.{Pack, PackExport, ProposePack}

  @header ~s([pack]\nname = "team"\nversion = "0.1.0"\ndescription = "Makes things."\nomunculus = ">= 0.1.0"\n)

  setup do
    dir = Fixtures.tmp_dir()
    team = Fixtures.pack(dir)
    toml = Path.join(team, "pack.toml")
    File.write!(toml, String.replace(File.read!(toml), "[pack]\nname = \"team\"\n", @header))
    File.write!(Path.join([team, "tools", "run.sh"]), "#!/bin/sh\n")
    File.chmod!(Path.join([team, "tools", "run.sh"]), 0o755)
    %{dir: dir, team: team, config_path: Fixtures.write_pack_config(dir)}
  end

  defp export(dir, out \\ "team.omupack"),
    do:
      PackExport.run(%{
        args: %{"path" => "team", "out" => out},
        config_path: Path.join(dir, "omunculus.toml")
      })

  defp install(config_path, args) do
    Pack.run(%{
      args: Map.merge(%{"models" => "lead=fast", "auth" => "vault=mine"}, args),
      config_path: config_path
    })
  end

  # An archive of `files`, whose manifest lists `listed` (the files by default).
  defp archive(dir, name, files, listed \\ nil, requirement \\ ">= 0.1.0") do
    listed = listed || files

    manifest =
      Encoder.encode(%{
        "pack" => %{
          "name" => "team",
          "version" => "0.1.0",
          "description" => "Makes things.",
          "omunculus" => requirement
        },
        "files" =>
          Map.new(listed, fn {path, data} ->
            {path, %{"sha256" => hash(data), "mode" => "644"}}
          end)
      })

    {:ok, tar} = :erl_tar.open(String.to_charlist(Path.join(dir, name)), [:write, :compressed])

    for {path, data} <- [{"omupack.toml", manifest} | Enum.to_list(files)] do
      :ok = :erl_tar.add(tar, {String.to_charlist(path), data}, [])
    end

    :ok = :erl_tar.close(tar)
    name
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp pack_toml(team), do: File.read!(Path.join(team, "pack.toml"))

  test "a pack exports to one file and installs from it into a project", %{
    dir: dir,
    team: team,
    config_path: config_path
  } do
    File.mkdir_p!(Path.join(team, ".git"))
    File.write!(Path.join([team, ".git", "HEAD"]), "ref")

    assert %{"ok" => true, "output" => output} = export(dir)
    file = Path.join(dir, "team.omupack")
    assert output == "#{file}\nsha256 #{hash(File.read!(file))}"

    {:ok, tar} = :erl_tar.table(String.to_charlist(file), [:compressed])
    names = Enum.map(tar, &to_string/1)
    assert "omupack.toml" in names and "pack.toml" in names and "tools/run.sh" in names
    refute Enum.any?(names, &String.starts_with?(&1, ".git"))

    assert %{"ok" => true, "output" => out} = install(config_path, %{"file" => "team.omupack"})
    folder = Path.join([dir, ".omunculus", "packs", "team-0.1.0"])
    assert out =~ "installed team 0.1.0 in #{folder}"
    assert out =~ "imported team"
    assert File.stat!(Path.join([folder, "tools", "run.sh"])).mode |> Bitwise.band(0o777) == 0o755

    assert [%{"path" => ".omunculus/packs/team-0.1.0"}] = Toml.decode_file!(config_path)["packs"]
    assert {:ok, %{agents: %{"chief" => %{model: "fast"}}}} = Config.load(config_path)

    # The same file again changes nothing.
    assert %{"ok" => true, "output" => again} = install(config_path, %{"file" => "team.omupack"})
    assert again =~ "team 0.1.0 is already in #{folder}"
    assert [_one] = Toml.decode_file!(config_path)["packs"]
  end

  test "without models it says what the pack is, runs and needs, and installs nothing", %{
    dir: dir,
    config_path: config_path
  } do
    export(dir)

    assert %{"ok" => false, "output" => output} =
             Pack.run(%{args: %{"file" => "team.omupack"}, config_path: config_path})

    assert output =~ "models needed for: lead"
    assert output =~ "team 0.1.0: Makes things."
    assert output =~ "agents: chief, hand"
    assert output =~ "runs these executables: tools/run.sh"
    assert output =~ "needs these logins: vault"
    assert output =~ "needs these secrets: deploy (KEY)"
    assert output =~ "job templates: none"
    refute File.exists?(Path.join(dir, ".omunculus"))
  end

  test "export needs the whole header", %{dir: dir, team: team} do
    original = pack_toml(team)

    for {from, to, key} <- [
          {~s(version = "0.1.0"\n), "", "version"},
          {~s(version = "0.1.0"), ~s(version = "one"), "version"},
          {~s(description = "Makes things."\n), "", "description"},
          {~s(omunculus = ">= 0.1.0"\n), "", "omunculus"},
          {~s(">= 0.1.0"), ~s("later"), "omunculus"}
        ] do
      File.write!(Path.join(team, "pack.toml"), String.replace(original, from, to))
      assert %{"ok" => false, "output" => output} = export(dir)
      assert output =~ "[pack] #{key} is missing or not valid"
    end
  end

  test "a symlink in the folder is not packed", %{dir: dir, team: team} do
    File.ln_s!("/etc/hostname", Path.join(team, "link"))
    assert %{"ok" => false, "output" => output} = export(dir)
    assert output =~ "link is a symlink"
  end

  test "a file for a newer omunculus is refused, saying which", %{
    dir: dir,
    team: team,
    config_path: config_path
  } do
    toml = String.replace(pack_toml(team), ">= 0.1.0", ">= 99.0.0")
    file = archive(dir, "new.omupack", %{"pack.toml" => toml}, nil, ">= 99.0.0")

    assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => file})
    assert output =~ "needs omunculus >= 99.0.0 and this is #{Omunculus.Tools.Version.current()}"

    File.write!(Path.join(team, "pack.toml"), toml)
    assert {:error, {"team", :omunculus, {">= 99.0.0", _running}}} = Packs.read(team)
    refute File.exists?(Path.join(dir, ".omunculus"))
  end

  describe "a file that is not what its manifest says" do
    setup %{team: team} do
      %{toml: pack_toml(team)}
    end

    test "a changed file", %{dir: dir, config_path: config_path, toml: toml} do
      file = archive(dir, "a.omupack", %{"pack.toml" => toml}, %{"pack.toml" => toml <> "\n"})
      assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => file})
      assert output =~ "pack.toml does not match the hash in the manifest"
    end

    test "a file the manifest lacks", %{dir: dir, config_path: config_path, toml: toml} do
      file =
        archive(dir, "a.omupack", %{"pack.toml" => toml, "tools/x" => "x"}, %{"pack.toml" => toml})

      assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => file})
      assert output =~ "tools/x is in the archive and not in the manifest"
    end

    test "a file the archive lacks", %{dir: dir, config_path: config_path, toml: toml} do
      file =
        archive(dir, "a.omupack", %{"pack.toml" => toml}, %{"pack.toml" => toml, "tools/x" => "x"})

      assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => file})
      assert output =~ "tools/x is in the manifest and not in the archive"
    end

    test "a path outside the folder", %{dir: dir, config_path: config_path, toml: toml} do
      for path <- ["../escape", "/abs/escape", "a/../../escape"] do
        files = %{"pack.toml" => toml, path => "x"}
        file = archive(dir, "a.omupack", files)
        assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => file})
        assert output =~ "unsafe entry"
      end

      refute File.exists?(Path.join(dir, "escape"))
    end

    test "a link", %{dir: dir, config_path: config_path, toml: toml} do
      File.ln_s!("/etc", Path.join(dir, "out"))

      {:ok, tar} =
        :erl_tar.open(String.to_charlist(Path.join(dir, "l.omupack")), [:write, :compressed])

      :ok = :erl_tar.add(tar, {~c"pack.toml", toml}, [])
      :ok = :erl_tar.add(tar, String.to_charlist(Path.join(dir, "out")), ~c"out", [])
      :ok = :erl_tar.close(tar)

      assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => "l.omupack"})
      assert output =~ "unsafe entry out: a symlink"
    end

    test "something that is not an archive, and a plain http URL", %{
      dir: dir,
      config_path: config_path
    } do
      File.write!(Path.join(dir, "n.omupack"), "hello")
      assert %{"ok" => false, "output" => output} = install(config_path, %{"file" => "n.omupack"})
      assert output =~ "not an omupack"

      assert %{
               "ok" => false,
               "output" => "cannot import http://x/team.omupack: only https URLs are fetched"
             } =
               install(config_path, %{"file" => "http://x/team.omupack"})
    end
  end

  test "another version is installed only with --upgrade, the old folder staying", %{
    dir: dir,
    team: team,
    config_path: config_path
  } do
    export(dir)
    assert %{"ok" => true} = install(config_path, %{"file" => "team.omupack"})

    File.write!(
      Path.join(team, "pack.toml"),
      String.replace(pack_toml(team), "0.1.0\"\ndesc", "0.2.0\"\ndesc")
    )

    export(dir, "team2.omupack")

    assert %{"ok" => false, "output" => output} =
             install(config_path, %{"file" => "team2.omupack"})

    assert output =~ "team is already imported at version 0.1.0"
    assert output =~ "add --upgrade"
    assert [%{"path" => ".omunculus/packs/team-0.1.0"}] = Toml.decode_file!(config_path)["packs"]

    assert %{"ok" => true, "output" => out} =
             install(config_path, %{"file" => "team2.omupack", "upgrade" => "true"})

    assert out =~ "upgraded team from 0.1.0; the old folder"
    assert out =~ "stays until you remove it by hand"
    assert [%{"path" => ".omunculus/packs/team-0.2.0"}] = Toml.decode_file!(config_path)["packs"]
    assert File.dir?(Path.join([dir, ".omunculus", "packs", "team-0.1.0"]))
    assert {:ok, _config} = Config.load(config_path)
  end

  test "the same version with other files is refused", %{
    dir: dir,
    team: team,
    config_path: config_path
  } do
    export(dir)
    assert %{"ok" => true} = install(config_path, %{"file" => "team.omupack"})

    File.write!(Path.join([team, "tools", "run.sh"]), "#!/bin/sh\necho changed\n")
    export(dir, "changed.omupack")

    assert %{"ok" => false, "output" => output} =
             install(config_path, %{"file" => "changed.omupack"})

    assert output =~ "holds a different team 0.1.0"
  end

  test "a proposal says what the file is and installs nothing", %{
    dir: dir,
    config_path: config_path
  } do
    export(dir)

    assert %{"ok" => true, "emit" => [%{"body" => body}]} =
             ProposePack.run(%{
               args: %{
                 "file" => "team.omupack",
                 "models" => %{"lead" => "fast"},
                 "auth" => %{"vault" => "mine"},
                 "reason" => "share"
               },
               config_path: config_path,
               roots: [dir]
             })

    assert body["reason"] =~ "runs these executables: tools/run.sh"
    assert body["reason"] =~ "team 0.1.0: Makes things."

    assert [%{"name" => "pack", "args" => %{"file" => file, "models" => "lead=fast"}}] =
             body["options"]["apply"]

    assert file == Path.join(dir, "team.omupack")
    refute File.exists?(Path.join(dir, ".omunculus"))
    refute Map.has_key?(Toml.decode_file!(config_path), "packs")
  end
end
