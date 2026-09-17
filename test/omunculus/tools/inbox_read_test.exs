defmodule Omunculus.Tools.InboxReadTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.InboxRead

  @input %{
    name: "inbox_read",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits inbox.read with the inbox_id" do
    input = %{@input | args: %{"inbox_id" => "inb_1"}}

    assert InboxRead.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [%{"type" => "inbox.read", "body" => %{"inbox_id" => "inb_1"}}]
           }
  end

  test "refuses without an inbox_id" do
    assert InboxRead.run(%{@input | args: %{}}) == %{
             "ok" => false,
             "output" => "inbox_id required",
             "emit" => []
           }
  end

  test "refuses a blank inbox_id" do
    assert InboxRead.run(%{@input | args: %{"inbox_id" => ""}}) == %{
             "ok" => false,
             "output" => "inbox_id required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers inbox_read with triggers == [\"cli\"]" do
    catalog = Catalog.unconfigured()

    assert %{"inbox_read" => manifest} = catalog
    assert manifest.triggers == ["cli"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "inbox_read")
    input = %{@input | args: %{"inbox_id" => "inb_1"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == InboxRead.run(input)["emit"]
  end
end
