defmodule Omunculus.Tools.InboxTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.Inbox

  @input %{
    name: "inbox",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "lists one line per inbox item" do
    items = [
      %{id: "inb_1", agent: "worker", work_id: "wrk_1", created_at: "t1", body: "acabei"},
      %{id: "inb_2", agent: "concierge", work_id: nil, created_at: "t2", body: nil}
    ]

    input = %{@input | view: %{"inbox" => items}}

    assert Inbox.run(input) == %{
             "ok" => true,
             "output" => "inb_1 worker: acabei\ninb_2 concierge: (sem texto)",
             "emit" => []
           }
  end

  test "reports an empty inbox when the list is empty" do
    input = %{@input | view: %{"inbox" => []}}
    assert Inbox.run(input) == %{"ok" => true, "output" => "inbox vazio", "emit" => []}
  end

  test "reports an empty inbox when the key is absent" do
    assert Inbox.run(@input) == %{"ok" => true, "output" => "inbox vazio", "emit" => []}
  end

  test "the builtin catalog discovers inbox with triggers == [\"cli\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"inbox" => manifest} = catalog
    assert manifest.triggers == ["cli"]
    assert manifest.views == ["inbox"]
  end

  test "the manifest wiring yields the same output as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "inbox")
    input = %{@input | view: %{"inbox" => []}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.output == Inbox.run(input)["output"]
  end
end
