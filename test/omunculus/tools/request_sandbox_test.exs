defmodule Omunculus.Tools.RequestSandboxTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.RequestSandbox

  @input %{
    name: "request_sandbox",
    args: %{},
    view: %{},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits a resource request for a supported sandbox capability" do
    input = %{
      @input
      | args: %{"name" => "sandbox.write", "reason" => "need to write files"}
    }

    assert RequestSandbox.run(input) == %{
             "ok" => true,
             "output" => "",
             "emit" => [
               %{
                 "type" => "request",
                 "body" => %{
                   "kind" => "resource",
                   "name" => "sandbox.write",
                   "reason" => "need to write files"
                 }
               }
             ]
           }
  end

  test "rejects an unsupported resource name" do
    input = %{@input | args: %{"name" => "sandbox.shell", "reason" => "x"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "unsupported resource: sandbox.shell",
             "emit" => []
           }
  end

  test "refuses without a name" do
    input = %{@input | args: %{"reason" => "why"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "name required",
             "emit" => []
           }
  end

  test "refuses without a reason" do
    input = %{@input | args: %{"name" => "sandbox.network"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "reason required",
             "emit" => []
           }
  end

  test "the builtin catalog discovers request_sandbox with triggers == [\"model\"]" do
    catalog = Catalog.unconfigured()

    assert %{"request_sandbox" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["sandbox"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "request_sandbox")
    input = %{@input | args: %{"name" => "sandbox.network", "reason" => "download packages"}}

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == RequestSandbox.run(input)["emit"]
  end
end
