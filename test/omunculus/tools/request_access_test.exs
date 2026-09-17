defmodule Omunculus.Tools.RequestAccessTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.RequestAccess

  @input %{
    name: "request_access",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits a request with kind, name and reason" do
    input = %{@input | args: %{"kind" => "tool", "name" => "write", "reason" => "need to write"}}

    assert RequestAccess.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "request",
                 "body" => %{"kind" => "tool", "name" => "write", "reason" => "need to write"}
               }
             ]
           }
  end

  test "emits supported sandbox resource requests" do
    input = %{
      @input
      | args: %{
          "kind" => "resource",
          "name" => "sandbox.network",
          "reason" => "needs a package download"
        }
    }

    assert RequestAccess.run(input)["emit"] == [
             %{
               "type" => "request",
               "body" => %{
                 "kind" => "resource",
                 "name" => "sandbox.network",
                 "reason" => "needs a package download"
               }
             }
           ]
  end

  test "rejects unsupported resources and access kinds" do
    resource = %{
      @input
      | args: %{"kind" => "resource", "name" => "sandbox.shell", "reason" => "x"}
    }

    kind = %{@input | args: %{"kind" => "secret", "name" => "vault", "reason" => "x"}}

    assert RequestAccess.run(resource) == %{
             "ok" => false,
             "output" => "unsupported resource: sandbox.shell",
             "emit" => []
           }

    assert RequestAccess.run(kind) == %{
             "ok" => false,
             "output" => "unsupported access kind: secret",
             "emit" => []
           }
  end

  test "refuses without a kind" do
    input = %{@input | args: %{"name" => "write", "reason" => "why"}}

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "kind required", "emit" => []}
  end

  test "refuses a blank kind" do
    input = %{@input | args: %{"kind" => "", "name" => "write", "reason" => "why"}}

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "kind required", "emit" => []}
  end

  test "refuses without a name" do
    input = %{@input | args: %{"kind" => "tool", "reason" => "why"}}

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "name required", "emit" => []}
  end

  test "refuses without a reason" do
    input = %{@input | args: %{"kind" => "tool", "name" => "write"}}

    assert RequestAccess.run(input) == %{
             "ok" => false,
             "output" => "reason required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers request_access with triggers == [\"model\"]" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))

    assert %{"request_access" => manifest} = catalog
    assert manifest.triggers == ["model"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.discover(Catalog.roots("/nonexistent"))
    manifest = Map.fetch!(catalog, "request_access")
    input = %{@input | args: %{"kind" => "directory", "name" => "./secrets", "reason" => "ler"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == RequestAccess.run(input)["emit"]
  end
end
