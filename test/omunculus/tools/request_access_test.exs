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
    input = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "kind" => "tool",
          "name" => "write",
          "reason" => "need to write"
        }
    }

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

  test "in a run with a work, comments the report on it before the request" do
    input = %{
      @input
      | work_id: "w1",
        args: %{
          "report" => "blocked on access",
          "kind" => "tool",
          "name" => "write",
          "reason" => "need to write"
        }
    }

    assert RequestAccess.run(input)["emit"] == [
             %{
               "type" => "comment",
               "body" => %{"work_id" => "w1", "body" => "blocked on access"}
             },
             %{
               "type" => "request",
               "body" => %{"kind" => "tool", "name" => "write", "reason" => "need to write"}
             }
           ]
  end

  test "refuses without a report" do
    input = %{@input | args: %{"kind" => "tool", "name" => "write", "reason" => "why"}}

    assert RequestAccess.run(input) == %{
             "ok" => false,
             "output" => "report required",
             "emit" => []
           }
  end

  test "rejects kind resource as an unsupported access kind" do
    input = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "kind" => "resource",
          "name" => "sandbox.network",
          "reason" => "needs a package download"
        }
    }

    assert RequestAccess.run(input) == %{
             "ok" => false,
             "output" => "unsupported access kind: resource",
             "emit" => []
           }
  end

  test "rejects unsupported access kinds" do
    kind = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "kind" => "secret",
          "name" => "vault",
          "reason" => "x"
        }
    }

    assert RequestAccess.run(kind) == %{
             "ok" => false,
             "output" => "unsupported access kind: secret",
             "emit" => []
           }
  end

  test "refuses without a kind" do
    input = %{
      @input
      | args: %{"report" => "blocked on access", "name" => "write", "reason" => "why"}
    }

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "kind required", "emit" => []}
  end

  test "refuses a blank kind" do
    input = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "kind" => "",
          "name" => "write",
          "reason" => "why"
        }
    }

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "kind required", "emit" => []}
  end

  test "refuses without a name" do
    input = %{
      @input
      | args: %{"report" => "blocked on access", "kind" => "tool", "reason" => "why"}
    }

    assert RequestAccess.run(input) == %{"ok" => false, "output" => "name required", "emit" => []}
  end

  test "refuses without a reason" do
    input = %{
      @input
      | args: %{"report" => "blocked on access", "kind" => "tool", "name" => "write"}
    }

    assert RequestAccess.run(input) == %{
             "ok" => false,
             "output" => "reason required",
             "emit" => []
           }
  end

  test "the builtin manifest is model-facing and ends the run through then" do
    catalog = Catalog.unconfigured()

    assert %{"request_access" => manifest} = catalog
    assert manifest.triggers == ["model"]
    assert manifest.chains == ["end"]
    assert manifest.then == ["end"]
  end

  test "the manifest wiring yields the same emit as calling the module directly" do
    catalog = Catalog.unconfigured()
    manifest = Map.fetch!(catalog, "request_access")

    input = %{
      @input
      | args: %{
          "report" => "blocked on access",
          "kind" => "directory",
          "name" => "./secrets",
          "reason" => "read"
        }
    }

    assert {:ok, result} = Invoke.call(manifest, input)
    assert result.emit == RequestAccess.run(input)["emit"]
  end
end
