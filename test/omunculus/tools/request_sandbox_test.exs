defmodule Omunculus.Tools.RequestSandboxTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tool.{Catalog, Invoke}
  alias Omunculus.Tools.{RequestAccess, RequestSandbox}

  @input %{
    name: "request_sandbox",
    args: %{},
    view: %{"grant_scopes" => ["agent"]},
    run_id: nil,
    work_id: nil,
    workspace: nil,
    roots: []
  }

  test "emits the request of request_access for kind resource" do
    for work_id <- [nil, "w1"] do
      input = %{
        @input
        | work_id: work_id,
          args: %{"report" => "blocked on access", "name" => "sandbox.write", "reason" => "why"}
      }

      assert RequestSandbox.run(input) ==
               RequestAccess.emit(input, "resource", "sandbox.write")
    end
  end

  test "refuses without a report" do
    input = %{@input | args: %{"name" => "sandbox.write", "reason" => "why"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "report required",
             "emit" => []
           }
  end

  test "rejects an unsupported resource name" do
    input = %{
      @input
      | args: %{"report" => "blocked on access", "name" => "sandbox.shell", "reason" => "x"}
    }

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "unsupported resource: sandbox.shell",
             "emit" => []
           }
  end

  test "refuses without a name" do
    input = %{@input | args: %{"report" => "blocked on access", "reason" => "why"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "name required",
             "emit" => []
           }
  end

  test "refuses without a reason" do
    input = %{@input | args: %{"report" => "blocked on access", "name" => "sandbox.network"}}

    assert RequestSandbox.run(input) == %{
             "ok" => false,
             "output" => "reason required",
             "emit" => []
           }
  end

  test "the builtin manifest is model-facing and ends the run through then" do
    catalog = Catalog.unconfigured()

    assert %{"request_sandbox" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.groups == ["sandbox"]
    assert manifest.chains == ["end"]
    assert manifest.then == ["end"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "request_sandbox")

    input = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "name" => "sandbox.network",
          "reason" => "download packages"
        }
    }

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == RequestSandbox.run(input)["emit"]
  end
end
