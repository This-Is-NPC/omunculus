defmodule Omunculus.ToolsTest do
  use ExUnit.Case, async: true

  alias Omunculus.{FS, Tools}

  test "schemas never include bash" do
    names = Tools.schemas(Tools.default_names()) |> Enum.map(&get_in(&1, ["function", "name"]))
    assert names == Tools.default_names()
    refute "bash" in names
  end

  test "grep returns path:line matches" do
    fs = FS.Memory.new(%{"lib/a.ex" => "foo\nbar foo\nbaz\n", "lib/b.ex" => "nope\n"})
    assert {:ok, body, _} = Tools.call("grep", %{"pattern" => "foo"}, fs, ["grep"])
    assert body =~ "lib/a.ex:1:foo"
    assert body =~ "lib/a.ex:2:bar foo"
    refute body =~ "lib/b.ex"
  end

  test "find filters by glob" do
    fs = FS.Memory.new(%{"lib/a.ex" => "", "lib/a.ts" => "", "README.md" => ""})
    assert {:ok, body, _} = Tools.call("find", %{"pattern" => "*.ex"}, fs, ["find"])
    assert body =~ "lib/a.ex"
    refute body =~ "a.ts"
  end

  test "ls suffixes directories" do
    fs = FS.Memory.new(%{"lib/a.ex" => "x", "README.md" => "y"})
    assert {:ok, body, _} = Tools.call("ls", %{}, fs, ["ls"])
    assert body =~ "lib/"
    assert body =~ "README.md"
  end

  test "overlapping edits are rejected" do
    fs = FS.Memory.new(%{"a.txt" => "abcdef"})

    args = %{
      "path" => "a.txt",
      "edits" => [
        %{"oldText" => "abc", "newText" => "X"},
        %{"oldText" => "cde", "newText" => "Y"}
      ]
    }

    assert {:error, :overlapping_edits} = Tools.call("edit", args, fs, ["edit"])
  end

  test "counter persists its value in the tool context" do
    context =
      Omunculus.Tool.Context.new(FS.Memory.new(), %{
        tools: %{"counter" => %{increment: 2}}
      })

    assert {:ok, "Counter value: 2", context} =
             Tools.call_context("counter", %{}, context, ["counter"])

    assert {:ok, "Counter value: 4", context} =
             Tools.call_context("counter", %{}, context, ["counter"])

    assert context.state["counter"] == %{value: 4, calls: 2, increment: 2}
  end
end
