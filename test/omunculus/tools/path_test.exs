defmodule Omunculus.Tools.PathTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Path, as: PathAuth

  setup do
    root = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/file.txt"), "hi")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "resolves a relative path against the first root", %{root: root} do
    assert PathAuth.resolve([root], "sub/file.txt") == {:ok, Path.join(root, "sub/file.txt")}
  end

  test "resolves an absolute path inside a root", %{root: root} do
    absolute = Path.join(root, "sub/file.txt")
    assert PathAuth.resolve([root], absolute) == {:ok, absolute}
  end

  test "resolves the root itself", %{root: root} do
    assert PathAuth.resolve([root], ".") == {:ok, root}
  end

  test "refuses a .. that escapes the root", %{root: root} do
    assert PathAuth.resolve([root], "../escape") ==
             {:error, "path outside roots: ../escape"}
  end

  test "refuses an absolute path outside every root", %{root: root} do
    assert PathAuth.resolve([root], "/etc/passwd") ==
             {:error, "path outside roots: /etc/passwd"}
  end

  test "accepts an absolute path under a later, non-first root", %{root: root} do
    other = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(other)
    on_exit(fn -> File.rm_rf!(other) end)

    absolute = Path.join(root, "sub/file.txt")
    assert PathAuth.resolve([other, root], absolute) == {:ok, absolute}
  end

  test "refuses when there are no roots" do
    assert PathAuth.resolve([], "anything") == {:error, "no roots"}
  end
end
