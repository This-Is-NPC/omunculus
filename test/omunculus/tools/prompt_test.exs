defmodule Omunculus.Tools.PromptTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Prompt

  @input %{
    name: "prompt",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "prints the assembled body" do
    input = %{@input | view: %{"prompt" => %{kind: "assembled", body: "hello model"}}}

    assert Prompt.run(input) == %{"ok" => true, "output" => "hello model", "emit" => []}
  end

  test "fails without a prompt row" do
    assert Prompt.run(@input) == %{
             "ok" => false,
             "output" => "no assembled prompt",
             "emit" => []
           }
  end

  test "the builtin catalog discovers prompt with triggers == [\"cli\"]" do
    catalog = Catalog.unconfigured()

    assert %{"prompt" => manifest} = catalog
    assert manifest.triggers == ["cli"]
    assert manifest.views == ["prompt"]
    assert manifest.groups == ["cli"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "prompt")
    input = %{@input | view: %{"prompt" => %{body: "wired"}}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Prompt.run(input)["output"]
  end
end
