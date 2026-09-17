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
    assert manifest.config == true
  end

  test "reads declared fields", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "compact_comments"
      kind = "tool"
      shape = "composite"
      triggers = ["model", "cli"]
      description = "Summarizes comments on the work."
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
    assert manifest.description == "Summarizes comments on the work."
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
      description = "line 1\\nline 2\\nline 3\\nline 4"
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert Manifest.card(manifest) == "- read: line 1\nline 2\nline 3"
  end

  test "card/1 stays on one line for a one-line description", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      description = "Reads a file."
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert Manifest.card(manifest) == "- read: Reads a file."
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

  test "a hook with events and without triggers loads with triggers == []", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      events = ["request"]
      command = ["./run"]
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.kind == "hook"
    assert manifest.events == ["request"]
    assert manifest.triggers == []
    refute Manifest.triggered_by?(manifest, "model")
    refute Manifest.triggered_by?(manifest, "cli")
  end

  test "a hook without events is invalid", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :events}}
  end

  test "a hook with an empty events list is invalid", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      events = []
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :events}}
  end

  test "a hook with triggers is invalid", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      events = ["request"]
      triggers = ["model"]
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :triggers}}
  end

  test "a tool with events is invalid", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      events = ["request"]
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :events}}
  end

  test "a tool with an agent is invalid", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      agent = "worker"
      command = ["./run"]
      """)

    assert Manifest.load(path) == {:error, {:invalid, :agent}}
  end

  test "a hook with an agent is parsed", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      events = ["request"]
      agent = "worker"
      command = ["./run"]
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.agent == "worker"
  end

  test "a hook without an agent defaults it to nil", %{dir: dir} do
    path =
      write_toml(dir, "hook.toml", """
      name = "on-request"
      kind = "hook"
      events = ["request"]
      command = ["./run"]
      """)

    assert {:ok, manifest} = Manifest.load(path)
    assert manifest.agent == nil
  end

  test "config defaults to true", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "read"
      kind = "tool"
      command = ["./run"]
      """)

    assert {:ok, %{config: true}} = Manifest.load(path)
  end

  test "config = false is valid only on the preset cli tool", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "preset"
      kind = "tool"
      triggers = ["cli"]
      config = false
      module = "Omunculus.Tools.Preset"
      """)

    assert {:ok, %{config: false, triggers: ["cli"]}} = Manifest.load(path)
  end

  test "config = false with a model trigger is rejected", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "preset"
      kind = "tool"
      triggers = ["model"]
      config = false
      module = "Omunculus.Tools.Preset"
      """)

    assert Manifest.load(path) == {:error, {:invalid, :config}}
  end

  test "config = false on a tool other than preset is rejected", %{dir: dir} do
    path =
      write_toml(dir, """
      name = "send"
      kind = "tool"
      triggers = ["cli"]
      config = false
      module = "Omunculus.Tools.Send"
      """)

    assert Manifest.load(path) == {:error, {:invalid, :config}}
  end

  test "parse/2 builds a manifest from a map", %{dir: dir} do
    assert {:ok, manifest} =
             Manifest.parse(
               %{
                 "name" => "echo",
                 "kind" => "tool",
                 "description" => "from a map",
                 "module" => "Omunculus.Tools.Comment"
               },
               dir
             )

    assert manifest.name == "echo"
    assert manifest.description == "from a map"
    assert manifest.dir == dir
  end
end
