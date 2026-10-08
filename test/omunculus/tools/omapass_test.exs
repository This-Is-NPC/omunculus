defmodule Omunculus.Tools.OmapassTest do
  # PATH and HOME are the process's own: no other test may run beside these.
  use ExUnit.Case, async: false

  alias Omunculus.Fixtures
  alias Omunculus.Tool.Catalog
  alias Omunculus.Tools.Omapass

  setup do
    path = System.get_env("PATH")
    home = System.get_env("HOME")

    on_exit(fn ->
      System.put_env("PATH", path)
      System.put_env("HOME", home)
    end)

    dir = Fixtures.tmp_dir()
    System.put_env("HOME", dir)
    System.put_env("PATH", Path.join(dir, "bin"))
    %{dir: dir}
  end

  defp described, do: Jason.decode!(Omapass.run(%{})["output"])

  # A stand-in omapass at `at` that lists two passwords and a Nostr key, or fails.
  defp fake(at, script) do
    File.mkdir_p!(Path.dirname(at))
    File.write!(at, "#!/bin/sh\n" <> script)
    File.chmod!(at, 0o755)
    at
  end

  @listing ~s(echo '[{"account":"zeta","folder":"","kind":""},{"account":"npub","folder":"","kind":"nostr"},{"account":"openrouter","folder":"ai","kind":""}]')

  test "without omapass it says it is not installed" do
    assert described() == %{"installed" => false}
  end

  test "lists the passwords of omapass on PATH, without its Nostr keys", %{dir: dir} do
    program = fake(Path.join([dir, "bin", "omapass"]), @listing)

    assert described() == %{
             "installed" => true,
             "program" => program,
             "accounts" => [
               %{"account" => "openrouter", "folder" => "ai"},
               %{"account" => "zeta", "folder" => ""}
             ]
           }
  end

  test "finds the Omarchy plugin under HOME", %{dir: dir} do
    program =
      fake(
        Path.join(dir, ".config/omarchy/plugins/io.github.this-is-npc.omapass/bin/omapass"),
        @listing
      )

    assert %{"installed" => true, "program" => ^program} = described()
  end

  test "says why it could not list them", %{dir: dir} do
    fake(Path.join([dir, "bin", "omapass"]), "exit 3")

    assert %{"installed" => true, "accounts" => [], "error" => "omapass list exited with 3"} =
             described()
  end

  test "the builtin catalog discovers omapass with triggers == [\"cli\"]" do
    assert %{"omapass" => manifest} = Catalog.unconfigured()
    assert manifest.triggers == ["cli"]
  end
end
