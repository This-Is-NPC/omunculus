defmodule Omunculus.InstallScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../install.sh", __DIR__)
  @core "omunculus-1.2.3-1-x86_64.pkg.tar.zst"
  @apps "omunculus-apps-1.2.3-1-any.pkg.tar.zst"

  # A release folder of fake packages with a matching SHA256SUMS.
  setup do
    dir = Omunculus.Fixtures.tmp_dir()
    for file <- [@core, @apps], do: File.write!(Path.join(dir, file), "fake #{file}")
    sums = for file <- [@core, @apps], do: "#{sha256(Path.join(dir, file))}  #{file}\n"
    File.write!(Path.join(dir, "SHA256SUMS"), sums)
    %{dir: dir}
  end

  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp install(dir, env \\ []) do
    System.cmd("bash", [@script],
      env: [{"BASE_URL", "file://" <> dir}, {"DRY_RUN", "1"} | env],
      stderr_to_stdout: true
    )
  end

  test "prints one pacman command naming both packages", %{dir: dir} do
    assert {out, 0} = install(dir)
    assert out =~ ~r{^sudo pacman -U \S+/#{@core} \S+/#{@apps}$}m
  end

  test "APPS=0 leaves the apps package out", %{dir: dir} do
    assert {out, 0} = install(dir, [{"APPS", "0"}])
    assert out =~ ~r{^sudo pacman -U \S+/#{@core}$}m
    refute out =~ "omunculus-apps"
  end

  test "refuses a package whose checksum does not match", %{dir: dir} do
    File.write!(Path.join(dir, @apps), "tampered")
    assert {out, 1} = install(dir)
    assert out =~ "#{@apps} does not match"
    refute out =~ "sudo pacman"
  end
end
