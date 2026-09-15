defmodule Omunculus.Tool.ManifestTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.Manifest

  setup do
    dir = Path.join(System.tmp_dir!(), Omunculus.Id.new())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_toml(dir, filename \\ "tool.toml", content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  test "applies defaults for optional fields", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      """)

    assert {:ok, manifest} = Manifest.load(path)

    assert manifest.name == "read"
    assert manifest.kind == "tool"
    assert manifest.shape == "simple"
    assert manifest.triggers == ["model"]
    assert manifest.description == ""
    assert manifest.tags == []
    assert manifest.groups == []
    assert manifest.parameters == %{}
    assert manifest.views == []
    assert manifest.events == []
    assert manifest.dir == dir
  end

  test "reads declared fields", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "compact_comments"
      kind = "tool"
      shape = "composite"
      triggers = ["model", "cli"]
      description = "Resume comments do work."
      tags = ["comments", "compact"]
      groups = ["work.write"]
      command = ["./run"]
      views = ["comments"]

      [parameters]
      type = "object"
      required = ["path"]
      """)

    assert {:ok, manifest} = Manifest.load(path)

    assert manifest.shape == "composite"
    assert manifest.triggers == ["model", "cli"]
    assert manifest.description == "Resume comments do work."
    assert manifest.tags == ["comments", "compact"]
    assert manifest.groups == ["work.write"]
    assert manifest.views == ["comments"]
    assert manifest.parameters == %{"type" => "object", "required" => ["path"]}
  end

  test "rejects a missing name", %{dir: dir} do
    path =
      write_toml(dir, """
      kind = "tool"
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :name}}
  end

  test "rejects an empty name", %{dir: dir} do
    path =
      write_toml(dir, """
      name = ""
      kind = "tool"
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :name}}
  end

  test "rejects a missing command", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      """)

    assert Manifest.load(path) == {:error, {:invalid, :command}}
  end

  test "rejects an empty command list", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = []
      """)

    assert Manifest.load(path) == {:error, {:invalid, :command}}
  end

  test "accepts a module instead of a command", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "send"
      kind = "tool"
      module = "Omunculus.Tools.Send"
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.module == "Omunculus.Tools.Send"
    assert manifest.command == nil
  end

  test "rejects neither command nor module", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      """)

    assert Manifest.load(path) == {:error, {:invalid, :command}}
  end

  test "rejects both command and module", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      module = "Omunculus.Tools.Send"
      """)

    assert Manifest.load(path) == {:error, {:invalid, :command}}
  end

  test "rejects an invalid kind", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "wat"
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :kind}}
  end

  test "rejects an unknown top-level key", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      speculative = true
      """)

    assert Manifest.load(path) == {:error, {:unknown_key, "speculative"}}
  end

  test "card/1 cuts the description to its first 3 lines", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      description = "linha 1\\nlinha 2\\nlinha 3\\nlinha 4"
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert Manifest.card(manifest) == "- read: linha 1\nlinha 2\nlinha 3"
  end

  test "card/1 stays on one line for a one-line description", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      description = "Le um arquivo."
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert Manifest.card(manifest) == "- read: Le um arquivo."
  end

  test "triggered_by?/2 checks the triggers list", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "send"
      kind = "tool"
      triggers = ["cli"]
      command = ["./run"]
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert Manifest.triggered_by?(manifest, "cli")
    refute Manifest.triggered_by?(manifest, "model")
  end
end
