defmodule Omunculus.Tools.IgnoreTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Ignore

  setup do
    root = Omunculus.Fixtures.tmp_dir()

    for file <- ~w(.gitignore keep.txt debug.log deps/lib.js src/main.py .git/config) do
      File.mkdir_p!(Path.dirname(Path.join(root, file)))
      File.write!(Path.join(root, file), if(file == ".gitignore", do: "*.log\ndeps/\n", else: ""))
    end

    %{root: root, paths: Path.wildcard(Path.join(root, "**/*"), match_dot: true)}
  end

  defp kept(paths, root),
    do: paths |> Ignore.reject(root) |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()

  test "outside a repository it leaves out only .git", %{root: root, paths: paths} do
    assert kept(paths, root) == ~w(.gitignore debug.log deps deps/lib.js keep.txt src src/main.py)
  end

  test "in a repository it leaves out what .gitignore ignores too", %{root: root, paths: paths} do
    File.rm_rf!(Path.join(root, ".git"))
    {_said, 0} = System.cmd("git", ["init", "--quiet"], cd: root)

    assert kept(paths, root) == ~w(.gitignore keep.txt src src/main.py)
  end
end
